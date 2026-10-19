import Foundation

/// Kennzeichen einer Mediathek (`mediathek.loomn.json` im Hauptordner). Über die ID findet die App
/// die Mediathek wieder, auch wenn die SSD auf einem anderen Mac unter einem anderen Pfad hängt.
struct Manifest: Codable, Equatable {
    static let fileName = "mediathek.loomn.json"
    static let type = "loomn-archiv-mediathek"
    static let schemaVersion = 1

    var type = Manifest.type
    var schema = Manifest.schemaVersion
    var id: String
    var name: String
    var created: Date
    var lastBuild: Int?
}

enum LibraryError: LocalizedError {
    case notALibrary(URL)
    case newer(Int)
    case damaged(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .notALibrary(let u): return "In „\(u.lastPathComponent)“ liegt keine Loomn-Archiv-Mediathek"
        case .newer(let v): return "Diese Mediathek stammt von einer neueren Version (Stand \(v)). Bitte zuerst die App aktualisieren."
        case .damaged(let s): return "Mediathek beschädigt: \(s)"
        case .missing(let s): return s
        }
    }
}

/// Ordner einer Mediathek:
/// ```
/// <Mediathek>/
///   mediathek.loomn.json      Kennung (ID, Version)
///   LIESMICH.txt
///   Material/JJJJ/JJJJ-MM/JJJJ-MM-TT/<Video> + <Video>.loomn.json
///   Archivdaten/katalog.json  Listen: Art, Format, Mood, Song, Tags, letzte Angaben
///   Archivdaten/index.sqlite  Suchindex (neu erzeugbar)
///   Archivdaten/Vorschauen/   Vorschaubilder (neu erzeugbar)
///   Archivdaten/Sicherungen/  Sicherungskopien vor Umbauten
/// ```
struct LibraryPaths {
    let root: URL
    var manifest: URL { root.appendingPathComponent(Manifest.fileName) }
    var material: URL { root.appendingPathComponent("Material", isDirectory: true) }
    var songs: URL { root.appendingPathComponent("Songs", isDirectory: true) }
    var data: URL { root.appendingPathComponent("Archivdaten", isDirectory: true) }
    var catalog: URL { data.appendingPathComponent("katalog.json") }
    var index: URL { data.appendingPathComponent("index.sqlite") }
    var previews: URL { data.appendingPathComponent("Vorschauen", isDirectory: true) }
    var backups: URL { data.appendingPathComponent("Sicherungen", isDirectory: true) }
    var readme: URL { root.appendingPathComponent("LIESMICH.txt") }

    func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
}

/// Eine geöffnete Mediathek. Alle Schreibzugriffe laufen hier nacheinander.
actor Library {
    nonisolated let paths: LibraryPaths
    private(set) var manifest: Manifest
    private(set) var catalog: Catalog
    private let index: ArchiveIndex
    /// Fingerabdrücke, die gerade importiert werden (gegen Doppelte im selben Stapel)
    private var pending: Set<String> = []

    nonisolated var root: URL { paths.root }
    var id: String { manifest.id }

    static let encoder: JSONEncoder = Sidecar.encoder
    static let decoder: JSONDecoder = Sidecar.decoder

    private init(paths: LibraryPaths, manifest: Manifest, catalog: Catalog, index: ArchiveIndex) {
        self.paths = paths
        self.manifest = manifest
        self.catalog = catalog
        self.index = index
    }

    // MARK: Anlegen und Öffnen

    /// Ist `url` selbst eine Mediathek?
    static func isLibrary(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(Manifest.fileName).path)
    }

    static func readManifest(_ root: URL) throws -> Manifest {
        let url = root.appendingPathComponent(Manifest.fileName)
        guard let data = try? Data(contentsOf: url) else { throw LibraryError.notALibrary(root) }
        guard let m = try? decoder.decode(Manifest.self, from: data), m.type == Manifest.type else {
            throw LibraryError.damaged("Kennungsdatei unlesbar")
        }
        return m
    }

    /// Neue Mediathek im Ordner `parent` anlegen (als Unterordner `name`).
    static func create(in parent: URL, name: String = "Loomn Archiv", build: Int = 0) throws -> Library {
        let fm = FileManager.default
        var root = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: root.path) {
            root = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        let paths = LibraryPaths(root: root)
        for d in [paths.root, paths.material, paths.data, paths.previews, paths.backups] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let manifest = Manifest(id: Catalog.newID(), name: root.lastPathComponent, created: Date(), lastBuild: build)
        try Sidecar.atomicWrite(encoder.encode(manifest), to: paths.manifest)
        let catalog = Catalog.makeDefault()
        try Sidecar.atomicWrite(encoder.encode(catalog), to: paths.catalog)
        try readmeText.write(to: paths.readme, atomically: true, encoding: .utf8)
        let index = try ArchiveIndex(url: paths.index)
        try index.createSchema(libraryID: manifest.id)
        return Library(paths: paths, manifest: manifest, catalog: catalog, index: index)
    }

    /// Vorhandene Mediathek öffnen. Hebt ältere Mediatheken an (mit Sicherung vorher) und baut
    /// einen fehlenden oder beschädigten Index aus den Begleitdateien neu auf.
    static func open(_ root: URL, build: Int = 0, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> Library {
        let paths = LibraryPaths(root: root)
        var manifest = try readManifest(root)
        if manifest.schema > Manifest.schemaVersion { throw LibraryError.newer(manifest.schema) }
        let fm = FileManager.default
        for d in [paths.material, paths.data, paths.previews, paths.backups] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        // Ältere Mediathek anheben (Schritte je Version kommen hier dazu)
        if manifest.schema < Manifest.schemaVersion {
            try backup(paths, reason: "vor-anhebung-\(manifest.schema)-auf-\(Manifest.schemaVersion)")
            manifest.schema = Manifest.schemaVersion
        }

        // Katalog: fehlt er oder ist er kaputt, wird er aus den Begleitdateien ergänzt
        var catalog = Catalog.makeDefault()
        var catalogLost = false
        if let data = try? Data(contentsOf: paths.catalog) {
            if let c = try? decoder.decode(Catalog.self, from: data) {
                if c.schema > Catalog.schemaVersion { throw LibraryError.newer(c.schema) }
                catalog = c
            } else {
                try? fm.copyItem(at: paths.catalog, to: paths.backups.appendingPathComponent("katalog-unlesbar-\(stamp()).json"))
                catalogLost = true
            }
        } else {
            catalogLost = true
        }
        if catalogLost {
            // Ohne Katalog keine Vorgabe-Listen erfinden, die es nie gab: nur Grundarten, Rest aus den Videos
            catalog.formats = []
            catalog.moods = []
        }

        // Index prüfen
        var needsRebuild = false
        var index: ArchiveIndex
        if fm.fileExists(atPath: paths.index.path),
           let ix = try? ArchiveIndex(url: paths.index), ix.isHealthy(),
           ix.schema == ArchiveIndex.schemaVersion, ix.meta("library") == manifest.id {
            index = ix
        } else {
            if fm.fileExists(atPath: paths.index.path) {
                try? fm.moveItem(at: paths.index, to: paths.backups.appendingPathComponent("index-\(stamp()).sqlite"))
            }
            index = try ArchiveIndex(url: paths.index)
            try index.createSchema(libraryID: manifest.id)
            needsRebuild = true
        }

        manifest.lastBuild = max(manifest.lastBuild ?? 0, build)
        try? Sidecar.atomicWrite(encoder.encode(manifest), to: paths.manifest)
        if !fm.fileExists(atPath: paths.readme.path) { try? readmeText.write(to: paths.readme, atomically: true, encoding: .utf8) }

        if needsRebuild || catalogLost {
            progress("Index wird aus den Begleitdateien neu aufgebaut")
            let records = try rebuildIndex(index, paths: paths, progress: progress)
            if catalogLost { SongAudio.absorbSidecars(into: &catalog, paths: paths) }
            for r in records { catalog.absorb(r) }
            try Sidecar.atomicWrite(encoder.encode(catalog), to: paths.catalog)
        }
        let existing = (try? index.all()) ?? []
        if catalog.upgradeDefaults(usedMoodIDs: Set(existing.flatMap { $0.moods.map(\.id) }),
                                   usedFormatIDs: Set(existing.map(\.format.id)),
                                   usedSongIDs: Set(existing.flatMap { $0.songs.map(\.id) })) {
            try Sidecar.atomicWrite(encoder.encode(catalog), to: paths.catalog)
        }
        return Library(paths: paths, manifest: manifest, catalog: catalog, index: index)
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    /// Sicherungskopie von Kennung, Katalog und Index.
    static func backup(_ paths: LibraryPaths, reason: String) throws {
        let fm = FileManager.default
        let dir = paths.backups.appendingPathComponent("\(stamp())_\(reason)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in [paths.manifest, paths.catalog, paths.index] where fm.fileExists(atPath: f.path) {
            try fm.copyItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent))
        }
    }

    // MARK: Index neu aufbauen

    /// Alle Begleitdateien unter Material/ lesen und den Index neu füllen.
    @discardableResult
    func rebuild(progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> Int {
        let records = try Self.rebuildIndex(index, paths: paths, progress: progress)
        absorb(records)
        return records.count
    }

    static func rebuildIndex(_ ix: ArchiveIndex, paths: LibraryPaths,
                             progress: @escaping @Sendable (String) -> Void) throws -> [VideoRecord] {
        let sidecars = findSidecars(in: paths.material)
        var records: [VideoRecord] = []
        var unreadable = 0
        for (i, url) in sidecars.enumerated() {
            if i % 200 == 0 { progress("Begleitdateien lesen: \(i) von \(sidecars.count)") }
            guard var r = try? Sidecar.read(url) else { unreadable += 1; continue }
            let video = url.deletingLastPathComponent().appendingPathComponent(r.file)
            guard FileManager.default.fileExists(atPath: video.path) else { unreadable += 1; continue }
            r.relPath = relative(video, to: paths.root)
            records.append(r)
        }
        // Doppelte IDs (z. B. von Hand kopierte Ordner): erste gewinnt
        var seen = Set<String>()
        records = records.filter { seen.insert($0.id).inserted }
        try ix.transaction {
            try ix.removeAll()
            for r in records { try ix.upsert(r) }
        }
        progress("Index fertig: \(records.count) Videos" + (unreadable > 0 ? ", \(unreadable) Begleitdateien unlesbar" : ""))
        return records
    }

    private func absorb(_ records: [VideoRecord]) {
        var c = catalog
        for r in records { c.absorb(r) }
        if c != catalog {
            catalog = c
            try? saveCatalog()
        }
    }

    /// Reste abgebrochener Kopien (.<id>.part) entfernen. Nie Videos, nur eigene Zwischendateien.
    static func removeLeftoverParts(_ paths: LibraryPaths) {
        guard let en = FileManager.default.enumerator(at: paths.material, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsPackageDescendants]) else { return }
        let old = Date().addingTimeInterval(-3600)
        for case let u as URL in en where u.lastPathComponent.hasPrefix(".") && u.lastPathComponent.hasSuffix(".part") {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if m < old { try? FileManager.default.removeItem(at: u) }
        }
    }

    static func findSidecars(in dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.lastPathComponent.hasSuffix(Sidecar.suffix) { out.append(u) }
        return out.sorted { $0.path < $1.path }
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard p.hasPrefix(r) else { return url.lastPathComponent }
        return String(p.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Lesen

    func allRecords() throws -> [VideoRecord] { try index.all().map { catalog.refresh($0) } }
    func currentCatalog() -> Catalog { catalog }
    func currentManifest() -> Manifest { manifest }
    func count() -> Int { index.count }

    // MARK: Katalog

    func saveCatalog() throws {
        try Sidecar.atomicWrite(Self.encoder.encode(catalog), to: paths.catalog)
    }

    func setCatalog(_ c: Catalog) throws {
        catalog = c
        try saveCatalog()
        SongAudio.writeSidecars(c, paths: paths)
    }

    // MARK: Import (die schweren Teile laufen außerhalb, hier nur das Eintragen)

    /// Bereits im Archiv oder gerade im Import? Gibt die ID des vorhandenen Videos zurück.
    func duplicate(of sha: String) -> String? {
        if let id = index.find(sha256: sha) { return id }
        return pending.contains(sha) ? "" : nil
    }

    /// Fingerabdruck für den laufenden Import reservieren. false = schon da.
    func reserve(_ sha: String) -> Bool {
        if index.find(sha256: sha) != nil || pending.contains(sha) { return false }
        pending.insert(sha)
        return true
    }

    func release(_ sha: String) { pending.remove(sha) }

    /// Geprüfte Kopie (`part`) unter endgültigem Namen ablegen, Begleitdatei schreiben, Index eintragen.
    func commit(part: URL, record draft: VideoRecord, ext: String) throws -> VideoRecord {
        defer { pending.remove(draft.sha256) }
        let fm = FileManager.default
        let dir = part.deletingLastPathComponent()
        var r = draft
        var short = 4
        var name = Naming.fileName(record: r, shortID: String(r.id.prefix(short)), ext: ext)
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path)
                || fm.fileExists(atPath: Sidecar.url(forVideo: dir.appendingPathComponent(name)).path) {
            short += 2
            name = Naming.fileName(record: r, shortID: String(r.id.replacingOccurrences(of: "-", with: "").prefix(short)), ext: ext)
        }
        let final = dir.appendingPathComponent(name)
        try fm.moveItem(at: part, to: final)
        r.file = name
        r.relPath = Self.relative(final, to: paths.root)
        do {
            try Sidecar.write(r, to: Sidecar.url(forVideo: final))
            try index.upsert(r)
        } catch {
            // Halbe Einträge vermeiden: Video zurück in eine .part-Datei, damit kein Waise entsteht
            try? fm.removeItem(at: Sidecar.url(forVideo: final))
            try? fm.removeItem(at: final)
            throw error
        }
        return r
    }

    func rememberImport(_ d: ImportDefaults, newTags: [String]) throws {
        catalog.lastImport = d
        catalog.noteTags(newTags)
        try saveCatalog()
    }

    // MARK: Bearbeiten

    /// Geänderte Datensätze speichern: Begleitdatei, Index und (wenn Art oder Song sich
    /// geändert haben) der lesbare Dateiname.
    func update(_ records: [VideoRecord]) throws -> [VideoRecord] {
        var out: [VideoRecord] = []
        let fm = FileManager.default
        for var r in records {
            r = catalog.refresh(r)
            let video = paths.url(r.relPath)
            guard fm.fileExists(atPath: video.path) else { throw LibraryError.missing("Video fehlt: \(r.relPath)") }
            if let newName = Naming.renamed(r.file, record: r), newName != r.file {
                let dir = video.deletingLastPathComponent()
                let target = dir.appendingPathComponent(newName)
                if !fm.fileExists(atPath: target.path) {
                    let oldSidecar = Sidecar.url(forVideo: video)
                    try fm.moveItem(at: video, to: target)
                    if fm.fileExists(atPath: oldSidecar.path) {
                        try? fm.moveItem(at: oldSidecar, to: Sidecar.url(forVideo: target))
                    }
                    r.file = newName
                    r.relPath = Self.relative(target, to: paths.root)
                }
            }
            try Sidecar.write(r, to: Sidecar.url(forVideo: paths.url(r.relPath)))
            try index.upsert(r)
            out.append(r)
        }
        return out
    }

    // MARK: Text

    static let readmeText = """
    LOOMN ARCHIV · MEDIATHEK

    Dieser Ordner ist eine vollständige Loomn-Archiv-Mediathek. Alles gehört hierher:
    Videos, Angaben, Listen, Suchindex und Vorschauen. Auf dem Mac liegt nur die App.

    Material/JJJJ/JJJJ-MM/JJJJ-MM-TT/
        Die Videos, abgelegt nach Entstehungstag, unverändert.
        Dateiname: Datum_Uhrzeit_Art_Song_Kennung.endung
        Daneben je eine Begleitdatei <Name>.loomn.json mit allen Angaben
        (Art, Song, Format, Mood, Beschreibung, Tags, Notizen). Sie ist die Wahrheit.

    Songs/<Song>_<Kennung>/
        Die Audiodateien der Songs, unverändert, eine Datei je Version
        (<Song>_v1_Datum.wav, <Song>_v2_Datum.wav, …). Daneben song.loomn-song.json
        mit Titel und allen Versionen.

    Archivdaten/
        katalog.json   Listen: Arten, Formate, Moods, Songs, Tags
        index.sqlite   Suchindex, wird bei Bedarf aus den Begleitdateien neu gebaut
        Vorschauen/    Vorschaubilder, jederzeit neu erzeugbar
        Sicherungen/   Kopien vor Umbauten

    Umzug auf einen anderen Mac: App auf den neuen Mac ziehen, diese Platte anstecken,
    „Vorhandene Mediathek öffnen“ wählen und auf diesen Ordner zeigen.

    Bitte keine Dateien in Material/ von Hand umbenennen oder verschieben, ohne die
    zugehörige .loomn.json mitzunehmen.
    """
}
