import AppKit
import SwiftUI

/// Zustand der App. Die Mediathek selbst (Dateien, Katalog, Index) liegt auf der SSD;
/// hier wird nur gemerkt, wo sie liegt.
@MainActor
final class AppModel: ObservableObject {

    enum LibraryState: Equatable {
        /// Noch keine Mediathek gewählt
        case none
        case opening(String)
        case online
        /// SSD nicht angeschlossen: nur Blättern aus der Kopie auf dem Mac
        case offline(volume: String)
        case failed(String)
    }

    // Ort der Mediathek (nur das liegt auf dem Mac)
    private enum Key {
        static let path = "library.path", id = "library.id", volume = "library.volume", name = "library.name"
        static let deleteOriginals = "import.deleteOriginals"
    }

    /// Gewählter Reiter in den Einstellungen (5 = Updates)
    @Published var settingsTab = 0
    @Published var showSettings = false
    /// Kompagnon-Fenster offen (Knopf oben leuchtet dann orange)
    @Published var companionOpen = false

    /// Was der Browser zeigt: alle Videos oder die Seite eines Songs
    enum Page: Equatable { case all, song(String), noSong }
    @Published var page: Page = .all {
        didSet { if page != oldValue { filter = LibraryFilter(); selection = [] } }
    }
    @Published private(set) var state: LibraryState = .none
    @Published private(set) var records: [VideoRecord] = [] { didSet { songStats = SongStats(records) } }
    /// Je Song: Anzahl Videos und letzter Import. Einmal je Änderung gerechnet, nicht bei jedem Zeichnen
    private(set) var songStats = SongStats([])
    @Published private(set) var catalog = Catalog.makeDefault() {
        didSet { if catalog != oldValue { publishCatalog() } }
    }
    @Published private(set) var manifest: Manifest?
    @Published private(set) var freeSpace: Int64?
    @Published private(set) var totalSpace: Int64?
    @Published var message: String?
    /// Kurzer Hinweis oben rechts, z. B. „3 neu aus Loomn Beat“ (verschwindet von selbst)
    @Published var inboxNote: String?

    // Bibliothek
    @Published var filter = LibraryFilter()
    @Published var sort: SortOrder = .createdDesc
    @Published var selection: Set<String> = [] {
        didSet {
            // Vorschau-Spalte klappt auf oder zu: Karten rutschen unter der Maus durch, Hover kurz sperren
            if oldValue.isEmpty != selection.isEmpty {
                layoutMoving = true
                layoutTask?.cancel()
                layoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if !Task.isCancelled { layoutMoving = false }
                }
            }
        }
    }
    @Published private(set) var layoutMoving = false
    private var layoutTask: Task<Void, Never>?

    // Import
    @Published var importDraft: ImportDraft?
    @Published private(set) var jobs = ImportJobs()

    // Umzug / Wartung
    @Published private(set) var busy: String?
    @Published private(set) var busyProgress: Double?

    let thumbs = ThumbStore()
    private(set) var library: Library?
    private var spaceTimer: Timer?
    private var inboxTimer: Timer?
    var inboxRunning = false
    /// Lieferungen, die schon einmal gescheitert sind: erst nach einem Neustart wieder versuchen
    var inboxFailed: Set<String> = []
    private var cacheSaveTask: Task<Void, Never>?

    var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    var online: Bool { state == .online }
    var libraryRoot: URL? { library?.root }
    var rememberedVolume: String { UserDefaults.standard.string(forKey: Key.volume) ?? "SSD" }
    /// Gibt es schon ein Archiv (offen, unterwegs oder ohne SSD)? Sonst wird beim ersten Reinziehen gefragt.
    var hasLibrary: Bool {
        switch state {
        case .none, .failed: return false
        default: return true
        }
    }

    var hasRemembered: Bool { UserDefaults.standard.string(forKey: Key.id) != nil }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.volumesChanged() }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.volumesChanged() }
        }
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSpace() }
        }
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInbox() }
        }
        reconnect()
    }

    // MARK: - Mediathek finden und öffnen

    /// Gemerkte Mediathek öffnen; ist die SSD nicht da, aus der Kopie auf dem Mac blättern.
    func reconnect() {
        let d = UserDefaults.standard
        guard let id = d.string(forKey: Key.id) else { state = .none; return }
        let hint = d.string(forKey: Key.path).map { URL(fileURLWithPath: $0, isDirectory: true) }
        state = .opening("Mediathek wird gesucht")
        Task.detached(priority: .userInitiated) {
            let found = Locator.find(id: id, hint: hint)
            await MainActor.run {
                if let found {
                    self.open(found)
                } else {
                    self.goOffline(id: id)
                }
            }
        }
    }

    private func goOffline(id: String) {
        library = nil
        let vol = rememberedVolume
        if let off = OfflineCache.load(id: id) {
            manifest = off.0
            catalog = off.1
            records = off.2
        }
        state = .offline(volume: vol)
        thumbs.reset(cacheDir: Previews.cacheDir(libraryID: id), libraryDir: nil)
        freeSpace = nil
        totalSpace = nil
    }

    private func volumesChanged() {
        switch state {
        case .offline:
            reconnect()
        case .online:
            if let root = library?.root, !FileManager.default.fileExists(atPath: root.appendingPathComponent(Manifest.fileName).path),
               let id = manifest?.id {
                goOffline(id: id)
            }
        default: break
        }
    }

    func open(_ root: URL) {
        state = .opening("Mediathek wird geöffnet")
        let build = self.build
        Task.detached(priority: .userInitiated) {
            do {
                let lib = try Library.open(root, build: build) { msg in
                    Task { @MainActor in self.state = .opening(msg) }
                }
                let recs = try await lib.allRecords()
                let cat = await lib.currentCatalog()
                let man = await lib.currentManifest()
                OfflineCache.save(lib.paths, id: man.id)
                await MainActor.run { self.didOpen(lib, records: recs, catalog: cat, manifest: man) }
            } catch {
                await MainActor.run { self.pendingImport = []; self.state = .failed(error.localizedDescription) }
            }
        }
    }

    private func didOpen(_ lib: Library, records: [VideoRecord], catalog: Catalog, manifest: Manifest) {
        library = lib
        self.records = records
        self.catalog = catalog
        self.manifest = manifest
        state = .online
        let d = UserDefaults.standard
        d.set(lib.root.path, forKey: Key.path)
        d.set(manifest.id, forKey: Key.id)
        d.set(FileOps.volumeName(lib.root) ?? lib.root.lastPathComponent, forKey: Key.volume)
        thumbs.reset(cacheDir: Previews.cacheDir(libraryID: manifest.id), libraryDir: lib.paths.previews)
        refreshSpace()
        selection = selection.filter { id in records.contains { $0.id == id } }
        if page == .all, let last = songsByActivity.first { page = .song(last.id) }
        generateMissingPreviews()
        publishCatalog()
        markAll(records)
        checkInbox()
        let paths = lib.paths
        Task.detached(priority: .background) { Library.removeLeftoverParts(paths) }
        if !pendingImport.isEmpty {
            let urls = pendingImport
            pendingImport = []
            beginImport(urls)
        }
    }

    func createLibrary(in parent: URL) {
        do {
            let lib = try Library.create(in: parent, build: build)
            open(lib.root)
        } catch {
            pendingImport = []
            message = "Mediathek konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }

    /// Videos, die reingezogen wurden, bevor es einen Speicherort gab. Sie gehen ins Import-Fenster,
    /// sobald das Archiv offen ist.
    private var pendingImport: [URL] = []

    /// Speicherort einmal wählen, ohne eigenen Startbildschirm: Liegt im gewählten Ordner schon
    /// ein Loomn Archiv (z. B. auf der SSD vom alten Mac), wird es geöffnet, sonst dort angelegt.
    func chooseStorage(then urls: [URL] = []) {
        guard let url = chooseFolder(prompt: "Hier speichern",
                                     message: "Wo soll dein Archiv liegen? Am besten auf der externen SSD. Liegt dort schon ein Archiv, wird es einfach geöffnet.")
        else { return }
        pendingImport = urls
        if let existing = Locator.libraries(under: url, depth: 2).first {
            open(existing)
            return
        }
        if FileOps.isInternal(url) {
            let a = NSAlert()
            a.messageText = "Dieser Ort ist auf dem Mac"
            a.informativeText = "Die Videos würden auf dem Mac landen, nicht auf der SSD. Trotzdem hier speichern?"
            a.addButton(withTitle: "Anderen Ort wählen")
            a.addButton(withTitle: "Trotzdem hier")
            if a.runModal() == .alertFirstButtonReturn { pendingImport = []; chooseStorage(then: urls); return }
        }
        createLibrary(in: url)
    }

    /// Ordner wählen und dort eine Mediathek suchen (der Ordner selbst oder bis zwei Ebenen darunter).
    func openExisting(_ url: URL) {
        let found = Locator.libraries(under: url, depth: 2)
        guard let first = found.first else {
            message = "In „\(url.lastPathComponent)“ wurde keine Mediathek gefunden. Bitte den Ordner wählen, in dem „\(Manifest.fileName)“ liegt."
            return
        }
        open(first)
    }

    func chooseFolder(prompt: String, message msg: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = prompt
        p.message = msg
        if let v = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])?
            .first(where: { !FileOps.isInternal($0) }) {
            p.directoryURL = v
        }
        return p.runModal() == .OK ? p.url : nil
    }

    func refreshSpace() {
        guard let root = library?.root else { return }
        freeSpace = FileOps.freeSpace(root)
        totalSpace = FileOps.totalSpace(root)
    }

    enum SpaceLevel { case ok, low, critical }

    /// Warnung rechtzeitig vor „voll“: unter 100 GB (gut zwei Wochen bei 10 Reels am Tag) bzw. 5 %.
    var spaceLevel: SpaceLevel {
        guard let free = freeSpace else { return .ok }
        let gb: Int64 = 1_000_000_000
        let pct = totalSpace.map { Double(free) / Double(max($0, 1)) } ?? 1
        if free < 25 * gb || pct < 0.02 { return .critical }
        if free < 100 * gb || pct < 0.05 { return .low }
        return .ok
    }

    // MARK: - Katalog pflegen

    func updateCatalog(_ change: (inout Catalog) -> Void) {
        var c = catalog
        change(&c)
        guard c != catalog else { return }
        catalog = c
        records = records.map { c.refresh($0) }
        guard let library else { message = "Änderungen an den Listen gehen nur mit angeschlossener SSD"; return }
        Task {
            do {
                try await library.setCatalog(c)
                scheduleCacheSave()
            } catch {
                message = "Listen konnten nicht gespeichert werden: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func newSong(_ title: String) -> SongItem? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var item: SongItem?
        updateCatalog { item = $0.songNamed(t) }
        return item ?? catalog.songs.first { $0.title.caseInsensitiveCompare(t) == .orderedSame }
    }

    /// Audiodatei als neuen Song oder als neue Version eines Songs ablegen (kopiert und geprüft).
    @discardableResult
    func addSongAudio(to songID: String?, title: String, from url: URL) async throws -> SongItem {
        guard online, let library else { throw FileOps.Failure("SSD ist nicht angeschlossen") }
        let duration = await SongAudio.duration(url)
        let song = try await library.addSongAudio(to: songID, title: title, from: url, duration: duration)
        let c = await library.currentCatalog()
        catalog = c
        records = records.map { c.refresh($0) }
        scheduleCacheSave()
        return song
    }

    /// Aktuelle Audiodatei eines Songs (nil ohne Audio oder ohne SSD)
    func songAudio(_ s: SongItem) -> URL? { s.current.flatMap(audioURL) }

    /// Wo die Audiodatei liegt; nil, wenn die SSD fehlt oder die Datei nicht da ist.
    func audioURL(_ v: SongVersion) -> URL? {
        guard let u = library?.paths.url(v.file), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    @discardableResult
    func newFormat(_ name: String) -> ListItem? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var item: ListItem?
        updateCatalog { item = $0.addFormat(t) }
        return item ?? catalog.formats.first { $0.name.caseInsensitiveCompare(t) == .orderedSame }
    }

    @discardableResult
    func newMood(_ name: String) -> ListItem? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var item: ListItem?
        updateCatalog { item = $0.addMood(t) }
        return item ?? catalog.moods.first { $0.name.caseInsensitiveCompare(t) == .orderedSame }
    }

    // MARK: - Einträge löschen (statt ausblenden)

    enum Entry { case format(String), mood(String), song(String), tag(String) }

    /// Videos, die den Eintrag tragen
    func usage(_ e: Entry) -> [VideoRecord] {
        switch e {
        case .format(let id): return records.filter { $0.format.id == id }
        case .mood(let id): return records.filter { $0.moods.contains { $0.id == id } }
        case .song(let id): return records.filter { $0.songs.contains { $0.id == id } }
        case .tag(let t): return records.filter { $0.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
        }
    }

    /// Videos, bei denen nach dem Löschen eine Pflichtangabe leer wäre und die einen Ersatz brauchen
    func needReplacement(_ e: Entry) -> [VideoRecord] {
        switch e {
        case .format: return usage(e)
        case .mood(let id): return usage(e).filter { $0.moods.allSatisfy { $0.id == id } }
        case .song(let id): return usage(e).filter { $0.songs.allSatisfy { $0.id == id } }
        case .tag: return []
        }
    }

    /// Eintrag löschen. Videos verlieren ihn; wo eine Pflichtangabe leer würde, kommt `replacement` hinein.
    func delete(_ e: Entry, replacement: String?) {
        var changed: [VideoRecord] = []
        for r in usage(e) {
            var n = r
            switch e {
            case .format:
                guard let rep = replacement, let f = catalog.format(rep) else { continue }
                n.format = Ref(id: f.id, name: f.name)
            case .mood(let id):
                n.moods.removeAll { $0.id == id }
                if n.moods.isEmpty, let rep = replacement, let m = catalog.mood(rep) { n.moods = [Ref(id: m.id, name: m.name)] }
                if n.moods.isEmpty { continue }
            case .song(let id):
                n.songs.removeAll { $0.id == id }
                if n.songs.isEmpty, let rep = replacement, let s = catalog.song(rep) { n.songs = [s.ref] }
                if n.songs.isEmpty { continue }
            case .tag(let t):
                n.tags.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
            }
            if n != r { changed.append(n) }
        }
        if !changed.isEmpty { save(changed) }
        updateCatalog { c in
            switch e {
            case .format(let id): c.removeFormat(id)
            case .mood(let id): c.removeMood(id)
            case .song(let id): c.removeSong(id)
            case .tag(let t): c.removeTag(t)
            }
        }
        switch e {
        case .format(let id): filter.formatIDs.remove(id)
        case .mood(let id): filter.moodIDs.remove(id)
        case .song(let id): if page == .song(id) { page = .all }
        case .tag(let t): filter.tags.remove(t)
        }
    }

    func scheduleCacheSave() {
        cacheSaveTask?.cancel()
        guard let lib = library, let id = manifest?.id else { return }
        cacheSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            OfflineCache.save(lib.paths, id: id)
        }
    }

    // MARK: - Bibliothek

    var visible: [VideoRecord] { sort.sort(filter.apply(records)) }

    /// Videos der aktuellen Song-Seite (Format, Mood, Art und Freitext aus dem Filter, Song aus der Seite)
    var pageRecords: [VideoRecord] {
        var f = filter
        f.songIDs = []
        f.noSong = false
        let base: [VideoRecord]
        switch page {
        case .all: return visible
        case .song(let id): base = records.filter { $0.songs.contains { $0.id == id } }
        case .noSong: base = records.filter(\.noSong)
        }
        return sort.sort(f.apply(base))
    }

    /// Songs, an denen zuletzt gearbeitet wurde, zuerst
    var songsByActivity: [SongItem] {
        let latest = songStats.lastUsed
        return catalog.visibleSongs.sorted { (latest[$0.id] ?? $0.created ?? .distantPast) > (latest[$1.id] ?? $1.created ?? .distantPast) }
    }

    func select(_ r: VideoRecord, in list: [VideoRecord]) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(r.id) { selection.remove(r.id) } else { selection.insert(r.id) }
        } else if mods.contains(.shift), let anchor = list.firstIndex(where: { selection.contains($0.id) }),
                  let i = list.firstIndex(where: { $0.id == r.id }) {
            selection = Set(list[min(anchor, i)...max(anchor, i)].map(\.id))
        } else {
            selection = selection == [r.id] ? [] : [r.id]
        }
    }

    func showSong(of r: VideoRecord) {
        page = r.songs.first.map { .song($0.id) } ?? .noSong
    }
    var recent: [VideoRecord] { Array(records.sorted { $0.importedAt > $1.importedAt }.prefix(24)) }
    var selected: [VideoRecord] { records.filter { selection.contains($0.id) } }

    func url(_ r: VideoRecord) -> URL? { library?.paths.url(r.relPath) }

    func showInFinder(_ r: VideoRecord) {
        guard let u = url(r), FileManager.default.fileExists(atPath: u.path) else { needSSD(); return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func openVideo(_ r: VideoRecord) {
        guard let u = url(r), FileManager.default.fileExists(atPath: u.path) else { needSSD(); return }
        NSWorkspace.shared.open(u)
    }

    func needSSD() {
        message = "SSD „\(rememberedVolume)“ anschließen"
    }

    func search(_ text: String) {
        page = .all
        filter = LibraryFilter()
        filter.text = text
        showSettings = false
    }

    /// Angaben mehrerer Videos speichern.
    func save(_ changed: [VideoRecord]) {
        guard let library else { needSSD(); return }
        Task {
            do {
                let saved = try await library.update(changed)
                var byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                for r in saved { byID[r.id] = r }
                records = Array(byID.values)
                markAll(saved)
                scheduleCacheSave()
            } catch {
                message = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Import

    /// Importfenster leer öffnen (Klick auf „Videos hierher ziehen“): Videos dazuziehen oder nur einen Song anlegen
    func openImport() {
        switch state {
        case .none, .failed:
            chooseStorage()
            return
        default: break
        }
        guard online else { needSSD(); return }
        if importDraft == nil { importDraft = ImportDraft(urls: [], catalog: catalog) }
    }

    func beginImport(_ urls: [URL]) {
        switch state {
        case .none, .failed:
            chooseStorage(then: urls)
            return
        default: break
        }
        guard online, let library else {
            needSSD()
            return
        }
        let videos = FileOps.collectVideos(urls)
        guard !videos.isEmpty else { message = "Keine Videos gefunden"; return }
        // Dateien, die schon in der Mediathek liegen, gar nicht erst anbieten
        let inside = videos.filter { $0.standardizedFileURL.path.hasPrefix(library.root.standardizedFileURL.path + "/") }
        let outside = videos.filter { !inside.contains($0) }
        guard !outside.isEmpty else { message = "Diese Videos liegen schon in der Mediathek"; return }
        if var d = importDraft {
            d.add(outside, catalog: catalog)
            importDraft = d
        } else {
            importDraft = ImportDraft(urls: outside, catalog: catalog)
        }
        hashDraft()
    }

    /// Fingerabdrücke im Hintergrund, damit „schon da“ schon im Fenster steht.
    private func hashDraft() {
        guard let draft = importDraft, let library else { return }
        for item in draft.items where item.sha == nil && !item.hashing {
            importDraft?.update(item.id) { $0.hashing = true }
            let url = item.url, id = item.id
            Task.detached(priority: .utility) {
                let sha = try? FileOps.sha256(url)
                let dup = sha != nil ? await library.duplicate(of: sha!) : nil
                await MainActor.run {
                    self.importDraft?.update(id) {
                        $0.sha = sha
                        $0.hashing = false
                        if let dup, !dup.isEmpty { $0.duplicateOf = dup }
                    }
                    self.importDraft?.markBatchDuplicates()
                }
            }
        }
    }

    func cancelImport() { importDraft = nil; pendingInput = [:] }

    /// Felder, in denen Enter „hinzufügen“ heißt (Song, + neu). Solange dort etwas getippt ist,
    /// löst Enter nicht den Import aus.
    var pendingInput: [String: Bool] = [:]

    /// Enter: alles mit vollständigen Angaben ins Archiv.
    func commitImport(keyboard: Bool = false) {
        if keyboard, pendingInput.values.contains(true) { return }
        guard let draft = importDraft, draft.ready, let library else { return }
        importDraft = nil
        pendingInput = [:]
        let items = draft.importable
        guard !items.isEmpty else { return }

        // Angaben fürs nächste Mal merken
        if let last = items.last?.attrs {
            let d = ImportDefaults(kindID: last.kindID, songIDs: last.songIDs, formatID: last.formatID,
                                   moodIDs: last.moodIDs, description: last.description, tags: last.tags)
            let tags = items.flatMap(\.attrs.tags)
            catalog.lastImport = d
            catalog.noteTags(tags)
            if let s = d.songIDs { page = s.first.map { .song($0) } ?? .noSong }
            Task { try? await library.rememberImport(d, newTags: tags) }
        }

        jobs.add(items.map { ImportJobs.Job(id: $0.id, name: $0.url.lastPathComponent, url: $0.url, sha: $0.sha, attrs: $0.attrs) })
        runJobs()
    }

    private var running = false

    private func runJobs() {
        guard !running, let library else { return }
        running = true
        Task {
            while let job = jobs.next() {
                jobs.set(job.id, .running("Kopieren"))
                do {
                    let res = try await Importer.importFile(job.url, sha: job.sha, attrs: job.attrs, into: library, allowDuplicate: true) { msg in
                        Task { @MainActor in self.jobs.set(job.id, .running(msg)) }
                    }
                    switch res {
                    case .imported(let r):
                        didImport(r)
                        jobs.set(job.id, .done)
                    case .duplicate:
                        jobs.set(job.id, .duplicate)
                    }
                } catch {
                    jobs.set(job.id, .failed(error.localizedDescription))
                    if !online { break }
                }
                refreshSpace()
            }
            running = false
            scheduleCacheSave()
            jobs.finishBatch()
            // Ohne Fehler verschwindet die Meldung von selbst, kein OK nötig
            if jobs.failed.isEmpty {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if jobs.active == 0, jobs.failed.isEmpty { jobs.clearFinished() }
            }
        }
    }

    func clearFinishedJobs() { jobs.clearFinished() }

    /// Neu im Archiv: in die Liste, Vorschau bauen, Datei für die Tools markieren
    func didImport(_ r: VideoRecord) {
        records.append(r)
        makePreview(r)
        markAll([r])
    }

    // MARK: - Vorschauen

    private var previewQueue: [VideoRecord] = []
    private var previewRunning = false

    private func makePreview(_ r: VideoRecord) {
        previewQueue.append(r)
        runPreviews()
    }

    private func generateMissingPreviews() {
        guard let lib = library else { return }
        let dir = lib.paths.previews
        let recs = records
        Task.detached(priority: .utility) {
            let missing = recs.filter { !Previews.exists($0.id, in: dir) }
            await MainActor.run {
                self.previewQueue.append(contentsOf: missing)
                self.runPreviews()
            }
        }
    }

    func regeneratePreviews() {
        previewQueue = records
        runPreviews()
    }

    private func runPreviews() {
        guard !previewRunning, let lib = library, let id = manifest?.id else { return }
        previewRunning = true
        let dirs = [lib.paths.previews, Previews.cacheDir(libraryID: id)]
        Task {
            while !previewQueue.isEmpty, library === lib {
                let r = previewQueue.removeFirst()
                let video = lib.paths.url(r.relPath)
                try? await Previews.generate(video: video, id: r.id, into: dirs)
                thumbs.invalidate(r.id)
            }
            previewRunning = false
        }
    }

    // MARK: - Wartung

    func rebuildIndex() {
        guard let library else { needSSD(); return }
        busy = "Index wird neu aufgebaut"
        Task {
            do {
                let n = try await library.rebuild { msg in Task { @MainActor in self.busy = msg } }
                records = try await library.allRecords()
                catalog = await library.currentCatalog()
                scheduleCacheSave()
                message = "Index neu aufgebaut: \(n) Videos"
            } catch {
                message = "Neuaufbau fehlgeschlagen: \(error.localizedDescription)"
            }
            busy = nil
        }
    }

    /// Mediathek an einen neuen Ort kopieren (mit Prüfung) und dort weiterarbeiten.
    func relocate(toParent parent: URL) {
        guard let src = library?.root else { needSSD(); return }
        guard jobs.active == 0 else { message = "Bitte warten, bis der Import fertig ist"; return }
        busy = "Mediathek wird kopiert"
        busyProgress = 0
        Task.detached(priority: .userInitiated) {
            do {
                let dst = try Relocation.copyLibrary(from: src, toParent: parent) { p, name in
                    Task { @MainActor in
                        self.busyProgress = p
                        self.busy = "Kopieren: \(name)"
                    }
                }
                await MainActor.run {
                    self.busy = nil
                    self.busyProgress = nil
                    self.open(dst)
                    self.message = "Umzug fertig. Die Mediathek liegt jetzt in „\(dst.path)“. Die alte Kopie in „\(src.path)“ kannst du löschen, sobald du alles geprüft hast."
                }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    self.busyProgress = nil
                    self.message = "Umzug abgebrochen: \(error.localizedDescription). Die bisherige Mediathek bleibt unverändert."
                }
            }
        }
    }

    func forgetLibrary() {
        let d = UserDefaults.standard
        for k in [Key.path, Key.id, Key.volume, Key.name] { d.removeObject(forKey: k) }
        library = nil
        records = []
        manifest = nil
        state = .none
        showSettings = false
    }
}

// MARK: - Import-Fenster: Stapel mit Angaben je Video

struct ImportDraft {
    struct Item: Identifiable {
        let id = UUID()
        var url: URL
        var size: Int64
        var sha: String?
        var hashing = false
        var duplicateOf: String?
        var batchDuplicate = false
        var attrs: Attrs

        /// Nur ein Hinweis, blockiert nichts
        var isDuplicate: Bool { duplicateOf != nil || batchDuplicate }
    }

    var items: [Item] = []
    /// Auswahl im Fenster; die Angaben gelten für die ausgewählten Videos
    var selection: Set<UUID> = []

    init(urls: [URL], catalog: Catalog) {
        add(urls, catalog: catalog)
    }

    mutating func add(_ urls: [URL], catalog: Catalog) {
        let have = Set(items.map { $0.url.standardizedFileURL.path })
        let d = catalog.lastImport
        // Songs/Formate/Moods, die es nicht mehr gibt oder die ausgeblendet sind, nicht vorbelegen
        let songs = d.songIDs?.filter { id in catalog.song(id).map { !$0.hidden } ?? false }
        let format = catalog.format(d.formatID).flatMap { $0.hidden ? nil : $0.id }
        let moods = d.moodIDs.filter { id in catalog.mood(id).map { !$0.hidden } ?? false }
        for u in urls where !have.contains(u.standardizedFileURL.path) {
            let kind = Naming.guessKind(u.lastPathComponent) ?? d.kindID ?? Kind.raw
            let a = Attrs(kindID: kind, songIDs: (songs?.isEmpty ?? true) && d.songIDs != [] ? nil : songs,
                          formatID: format, moodIDs: moods, description: d.description, tags: d.tags)
            let item = Item(url: u, size: FileOps.size(u), attrs: a)
            items.append(item)
            selection.insert(item.id)
        }
    }

    mutating func update(_ id: UUID, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    mutating func markBatchDuplicates() {
        var seen = Set<String>()
        for i in items.indices {
            guard let sha = items[i].sha else { continue }
            items[i].batchDuplicate = !seen.insert(sha).inserted
        }
    }

    mutating func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Angehakte Videos gehen ins Archiv, abgewählte nicht. Gleiche Dateien werden nicht abgelehnt.
    var importable: [Item] { items.filter { selection.contains($0.id) } }
    var ready: Bool { !importable.isEmpty && importable.allSatisfy(\.attrs.complete) }
    var incomplete: Int { importable.filter { !$0.attrs.complete }.count }
    var selectedItems: [Item] { items.filter { selection.contains($0.id) } }
}

// MARK: - Laufende Kopien

struct ImportJobs {
    enum Status: Equatable {
        case waiting, running(String), done, duplicate, failed(String)
    }

    struct Job: Identifiable {
        let id: UUID
        let name: String
        let url: URL
        let sha: String?
        let attrs: Attrs
        var status: Status = .waiting
    }

    private(set) var list: [Job] = []
    private(set) var lastBatch: (done: Int, duplicates: Int, failed: Int)?

    mutating func add(_ jobs: [Job]) {
        if active == 0 { list.removeAll { $0.status == .done || $0.status == .duplicate } }
        list += jobs
    }

    mutating func next() -> Job? { list.first { $0.status == .waiting } }

    mutating func set(_ id: UUID, _ s: Status) {
        if let i = list.firstIndex(where: { $0.id == id }) { list[i].status = s }
    }

    var active: Int { list.filter { if case .waiting = $0.status { return true }; if case .running = $0.status { return true }; return false }.count }
    var done: Int { list.filter { $0.status == .done }.count }
    var failed: [Job] { list.filter { if case .failed = $0.status { return true }; return false } }
    var duplicates: Int { list.filter { $0.status == .duplicate }.count }

    mutating func finishBatch() { lastBatch = (done, duplicates, failed.count) }
    mutating func clearFinished() {
        list.removeAll { if case .running = $0.status { return false }; return $0.status != .waiting }
        lastBatch = nil
    }
}

struct SongStats {
    var count: [String: Int] = [:]
    var lastUsed: [String: Date] = [:]

    init(_ records: [VideoRecord]) {
        for r in records {
            for s in r.songs {
                count[s.id, default: 0] += 1
                if (lastUsed[s.id] ?? .distantPast) < r.importedAt { lastUsed[s.id] = r.importedAt }
            }
        }
    }
}
