import AppKit
import Foundation

/// Annahmestelle „Export direkt nach archivn“ (Übergabe editn Nr. 4, Version 1).
///
/// Ein Tool rendert seinen Export in einen Ordner `An archivn`, legt `<datei>.loomn.json` daneben und ruft
/// `archivn://aufnehmen?datei=<pfad>` auf. archivn übernimmt das Video ohne Nachfrage als EDIT (geprüfte Kopie
/// auf die SSD, danach Video und Begleitdatei im Übergabe-Ordner gelöscht, also verschoben) und antwortet über
/// `DistributedNotificationCenter` mit `de.loomn.archiv.aufgenommen`. Liegengebliebenes holt archivn beim
/// Start und alle 5 Sekunden aus den bekannten `An archivn`-Ordnern.
///
/// Dauerhaft: Feldnamen nie umbenennen oder entfernen, nur neue optionale Felder; unbekannte Felder ignorieren.
enum ExportAnnahme {
    static let ordnerName = "An archivn"
    static let endung = ".loomn.json"
    static let antwortName = Notification.Name("de.loomn.archiv.aufgenommen")
    private static let ordnerSchluessel = "loomn.export.ordner"

    // MARK: - Begleitdatei

    struct Begleitung: Codable, Equatable {
        struct Projekt: Codable, Equatable { var name: String?; var pfad: String? }
        struct Video: Codable, Equatable {
            var breite: Int?; var hoehe: Int?; var format: String?; var dauer: Double?
            var fps: Double?; var ton: Bool?; var codec: String?
        }
        struct Song: Codable, Equatable { var name: String?; var pfad: String?; var archivId: String?; var bpm: Double? }
        struct Quelle: Codable, Equatable { var name: String?; var pfad: String?; var archivId: String? }

        var loomnExport: Int
        var tool: String?
        var toolName: String?
        var toolBuild: Int?
        /// Optional (archivn-Vorschlag): Bundle-ID des Tools, an die die Antwort geht
        var bundleId: String?
        var erstellt: String?
        var datei: String
        var titel: String?
        var projekt: Projekt?
        var video: Video?
        var song: Song?
        var quellen: [Quelle]?
        var rueckweg: String?

        var anzeigename: String { toolName ?? tool ?? "einem Tool" }
    }

    /// Eine geprüfte Lieferung: Video, Begleitdatei und ihr Inhalt
    struct Fund {
        var video: URL
        var json: URL
        var begleitung: Begleitung
        var roh: JSONValue
    }

    struct Ablehnung: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static func begleitdatei(zu video: URL) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(video.lastPathComponent + endung)
    }

    /// Nur Dateien in einem Ordner `An archivn` mit gültiger Begleitdatei daneben. Alles andere wird abgelehnt,
    /// damit nicht irgendeine Webseite über `archivn://` Dateien verschieben lässt.
    static func pruefe(_ angegeben: URL) throws -> Fund {
        let fm = FileManager.default
        let video = angegeben.standardizedFileURL.resolvingSymlinksInPath()
        guard video.deletingLastPathComponent().lastPathComponent == ordnerName else {
            throw Ablehnung("Die Datei liegt nicht in einem Ordner „\(ordnerName)“")
        }
        var istOrdner: ObjCBool = false
        guard fm.fileExists(atPath: video.path, isDirectory: &istOrdner), !istOrdner.boolValue else {
            throw Ablehnung("Die Datei ist nicht da")
        }
        guard FileOps.isVideo(video) else { throw Ablehnung("Die Datei ist kein Video") }
        let json = begleitdatei(zu: video)
        guard let daten = try? Data(contentsOf: json) else { throw Ablehnung("Die Begleitdatei fehlt") }
        guard let b = try? JSONDecoder().decode(Begleitung.self, from: daten), b.loomnExport >= 1 else {
            throw Ablehnung("Die Begleitdatei ist kein Loomn-Export")
        }
        guard b.datei == video.lastPathComponent else { throw Ablehnung("Die Begleitdatei gehört zu einer anderen Datei") }
        let roh = (try? JSONDecoder().decode(JSONValue.self, from: daten)) ?? .null
        return Fund(video: video, json: json, begleitung: b, roh: roh)
    }

    // MARK: - Bekannte Übergabe-Ordner

    static var standardOrdner: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Loomn", isDirectory: true)
            .appendingPathComponent(ordnerName, isDirectory: true)
    }

    static var bekannteOrdner: [URL] {
        let gemerkt = UserDefaults.standard.stringArray(forKey: ordnerSchluessel) ?? []
        var out = [standardOrdner]
        for p in gemerkt {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if !out.contains(u) { out.append(u) }
        }
        return out
    }

    /// Ordner merken, damit Liegengebliebenes beim nächsten Start gefunden wird. Nur Ordner `An archivn`.
    static func merke(_ fund: Fund) {
        var kandidaten = [fund.video.deletingLastPathComponent()]
        if let r = fund.begleitung.rueckweg, !r.isEmpty { kandidaten.append(URL(fileURLWithPath: r, isDirectory: true)) }
        var gemerkt = UserDefaults.standard.stringArray(forKey: ordnerSchluessel) ?? []
        for k in kandidaten {
            let p = k.standardizedFileURL.resolvingSymlinksInPath().path
            if k.standardizedFileURL.lastPathComponent == ordnerName, !gemerkt.contains(p) { gemerkt.append(p) }
        }
        UserDefaults.standard.set(gemerkt, forKey: ordnerSchluessel)
    }

    /// Videos mit Begleitdatei in den Ordnern, deren Begleitdatei älter als `alter` Sekunden ist
    /// (frische kommen über den Link, dann wird nicht doppelt gegriffen).
    static func liegengeblieben(in ordner: [URL], alter: TimeInterval) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for o in ordner {
            guard let inhalt = try? fm.contentsOfDirectory(at: o, includingPropertiesForKeys: [.contentModificationDateKey],
                                                           options: [.skipsHiddenFiles]) else { continue }
            for json in inhalt where json.lastPathComponent.hasSuffix(endung) {
                let name = String(json.lastPathComponent.dropLast(endung.count))
                let video = o.appendingPathComponent(name)
                guard fm.fileExists(atPath: video.path) else { continue }
                let geaendert = (try? json.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(geaendert) >= alter { out.append(video) }
            }
        }
        return out
    }

    // MARK: - Zuordnung

    /// Was archivn aus der Begleitdatei und den Ausgangsclips ableitet
    struct Plan: Equatable {
        /// vorhandener Song
        var songID: String?
        /// neuer Song mit diesem Titel (nur, wenn ein Archiv-Song gemeint ist, den es noch nicht gibt)
        var neuerSong: String?
        var herkunft: [String] = []
        var formatID: String?
        var moodIDs: [String] = []
        var tags: [String] = []
        var beschreibung = ""
        var projekt: String?
    }

    private static func gleich(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// „Nachtfahrt · LION“ → „Nachtfahrt“
    private static func titel(_ s: String) -> String {
        (s.components(separatedBy: " · ").first ?? s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func songMitTitel(_ t: String, _ c: Catalog) -> SongItem? {
        let t = titel(t)
        guard !t.isEmpty else { return nil }
        return c.songs.first { gleich($0.title, t) }
    }

    /// Song, Herkunft, Format, Moods und Tags. Reihenfolge beim Song: Archiv-Markierung aus editn,
    /// Markierung an der Audiodatei, Dateiname einer Song-Version, gemeinsamer Song der Ausgangsclips.
    static func plan(_ b: Begleitung, catalog c: Catalog, records: [VideoRecord],
                     attribut: (URL, String) -> String? = { ExportAnnahme.leseAttribut($0, $1) }) -> Plan {
        var p = Plan()
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Ausgangsclips: archivId, sonst die Markierung an der Datei
        for q in b.quellen ?? [] {
            var id = q.archivId?.trimmingCharacters(in: .whitespaces)
            if id?.isEmpty != false, let pfad = q.pfad { id = attribut(URL(fileURLWithPath: pfad), LoomnArchiv.idAttribut) }
            if let id, !id.isEmpty, byID[id] != nil, !p.herkunft.contains(id) { p.herkunft.append(id) }
        }
        let quellen = p.herkunft.compactMap { byID[$0] }

        // Song
        if let s = b.song {
            if let id = s.archivId, let item = c.song(id) { p.songID = item.id }
            else if let t = s.archivId, let item = songMitTitel(t, c) { p.songID = item.id }
            else if let pfad = s.pfad, let t = attribut(URL(fileURLWithPath: pfad), LoomnArchiv.songAttribut),
                    let item = songMitTitel(t, c) { p.songID = item.id }
            else if let name = s.name, !name.isEmpty,
                    let item = c.songs.first(where: { $0.versions.contains { v in gleich(v.originalName, name) } }) { p.songID = item.id }
        }
        if p.songID == nil {
            let songs = Set(quellen.compactMap { $0.songs.first?.id })
            if songs.count == 1, let id = songs.first, c.song(id) != nil { p.songID = id }
        }
        if p.songID == nil, let s = b.song {
            // Archiv-Song, den es (noch) nicht gibt: anlegen wie beim Eintippen
            let markiert = s.archivId ?? s.pfad.flatMap { attribut(URL(fileURLWithPath: $0), LoomnArchiv.songAttribut) }
            if let m = markiert.map(titel), !m.isEmpty, !looksLikeID(m) { p.neuerSong = m }
        }

        // Format, Moods, Tags von den Ausgangsclips (häufigste zuerst)
        func haeufigste(_ werte: [String]) -> [String] {
            var zahl: [String: Int] = [:]
            var reihe: [String] = []
            for w in werte where !w.isEmpty {
                if zahl[w] == nil { reihe.append(w) }
                zahl[w, default: 0] += 1
            }
            return reihe.enumerated().sorted { (zahl[$0.element]!, -$0.offset) > (zahl[$1.element]!, -$1.offset) }.map(\.element)
        }
        p.formatID = haeufigste(quellen.map(\.format.id)).first { c.format($0) != nil }
        p.moodIDs = haeufigste(quellen.flatMap { $0.moods.map(\.id) }).filter { c.mood($0) != nil }
        p.tags = Array(haeufigste(quellen.flatMap(\.tags)).prefix(3))

        let projekt = b.projekt?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        p.projekt = projekt?.isEmpty == false ? projekt : nil
        let t = (b.titel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        p.beschreibung = t.isEmpty ? (p.projekt ?? "") : t
        return p
    }

    /// UUIDs (Archiv-IDs) nie als Songtitel anlegen
    private static func looksLikeID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    static func leseAttribut(_ url: URL, _ name: String) -> String? {
        name == LoomnArchiv.idAttribut ? LoomnArchiv.archivID(von: url) : LoomnArchiv.song(von: url)
    }

    // MARK: - Übernehmen und antworten

    /// Video als geprüfte Kopie in die Mediathek, danach Video und Begleitdatei im Übergabe-Ordner löschen.
    /// Gibt Archiv-ID und Ort in der Mediathek zurück.
    static func uebernimm(_ fund: Fund, attrs: Attrs, projekt: Ref?, herkunft: [String],
                          into lib: Library) async throws -> (id: String, ort: URL) {
        var extra: [String: JSONValue] = ["werkzeug": .string(fund.begleitung.anzeigename), "loomnExport": fund.roh]
        if !herkunft.isEmpty { extra["herkunft"] = .array(herkunft.map { .string($0) }) }
        let res = try await Importer.importFile(fund.video, sha: nil, attrs: attrs, into: lib, source: extra, project: projekt)
        let id: String
        switch res {
        case .imported(let r): id = r.id
        case .duplicate(let existing): id = existing
        }
        guard !id.isEmpty, let rec = try await lib.allRecords().first(where: { $0.id == id }) else {
            throw Ablehnung("Das Video ist nicht im Archiv angekommen")
        }
        let ort = lib.paths.url(rec.relPath)
        // erst löschen, wenn die geprüfte Kopie liegt
        try? FileManager.default.removeItem(at: fund.video)
        try? FileManager.default.removeItem(at: fund.json)
        return (id, ort)
    }

    /// Wohin die Antwort geht: `bundleId` aus der Begleitdatei, sonst bekannte Tools
    static func empfaenger(_ b: Begleitung?) -> String {
        if let id = b?.bundleId, !id.isEmpty { return id }
        switch (b?.tool ?? "").lowercased() {
        case "moshn", "beatmosh", "editn": return "com.loomn.beatmosh"
        default: return b?.tool ?? ""
        }
    }

    static func antwortJSON(datei: String, ok: Bool, id: String? = nil, ort: URL? = nil, grund: String? = nil) -> String {
        var d: [String: Any] = ["loomnExport": 1, "datei": datei, "ok": ok]
        if let id { d["id"] = id }
        if let ort { d["ort"] = ort.path }
        if let grund { d["grund"] = grund }
        let daten = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])) ?? Data()
        return String(decoding: daten, as: UTF8.self)
    }

    static func antworte(_ b: Begleitung?, datei: String, ok: Bool, id: String? = nil, ort: URL? = nil, grund: String? = nil) {
        let json = antwortJSON(datei: datei, ok: ok, id: id, ort: ort, grund: grund)
        DistributedNotificationCenter.default().postNotificationName(antwortName, object: empfaenger(b),
                                                                     userInfo: ["json": json], deliverImmediately: true)
    }
}

// MARK: - archivn-Seite im Modell

extension AppModel {
    /// Vom Link `archivn://aufnehmen?datei=…`
    func aufnehmen(_ video: URL) {
        guard Screenshots.requested == nil else { return }
        let p = video.standardizedFileURL.resolvingSymlinksInPath().path
        if !exportQueue.contains(p) { exportQueue.append(p) }
        runExports()
    }

    /// Liegengebliebenes aus den bekannten Übergabe-Ordnern (beim Start und alle 5 Sekunden)
    func checkExports() {
        guard online, Screenshots.requested == nil else { return }
        let ordner = ExportAnnahme.bekannteOrdner
        let failed = exportFailed
        Task {
            let liegt = await Task.detached(priority: .utility) {
                ExportAnnahme.liegengeblieben(in: ordner, alter: 30)
            }.value
            for v in liegt {
                let p = v.standardizedFileURL.resolvingSymlinksInPath().path
                if !failed.contains(p) && !exportQueue.contains(p) && !exportBusy.contains(p) { exportQueue.append(p) }
            }
            runExports()
        }
    }

    func runExports() {
        guard !exportRunning, !exportQueue.isEmpty else { return }
        switch state {
        case .opening:
            return // kommt wieder, sobald die Mediathek offen ist (checkInbox)
        case .online:
            break
        default:
            // Ohne SSD: liegen lassen, Antwort geben; beim nächsten Mal (SSD da) holt archivn es selbst
            let grund = "Die Mediathek-SSD ist nicht angeschlossen. Das Video bleibt in „\(ExportAnnahme.ordnerName)“ und kommt automatisch, sobald sie da ist."
            for p in exportQueue {
                let url = URL(fileURLWithPath: p)
                let fund = try? ExportAnnahme.pruefe(url)
                if let fund { ExportAnnahme.merke(fund) }
                ExportAnnahme.antworte(fund?.begleitung, datei: url.lastPathComponent, ok: false, grund: grund)
            }
            exportQueue = []
            return
        }
        exportRunning = true
        Task {
            defer {
                exportRunning = false
                if !exportQueue.isEmpty { runExports() }
            }
            var neu: [String: Int] = [:]
            while online, let library, !exportQueue.isEmpty {
                let p = exportQueue.removeFirst()
                let url = URL(fileURLWithPath: p)
                exportBusy.insert(p)
                defer { exportBusy.remove(p) }
                let fund: ExportAnnahme.Fund
                do {
                    fund = try ExportAnnahme.pruefe(url)
                } catch {
                    exportFailed.insert(p)
                    ExportAnnahme.antworte(nil, datei: url.lastPathComponent, ok: false, grund: error.localizedDescription)
                    continue
                }
                ExportAnnahme.merke(fund)
                do {
                    let plan = ExportAnnahme.plan(fund.begleitung, catalog: catalog, records: records)
                    var a = Attrs()
                    a.kindID = Kind.edit
                    if let id = plan.songID { a.songIDs = [id] }
                    else if let t = plan.neuerSong, let s = newSong(t) { a.songIDs = [s.id] }
                    else { a.songIDs = [] }
                    a.formatID = plan.formatID
                    a.moodIDs = plan.moodIDs
                    a.tags = plan.tags
                    a.description = plan.beschreibung
                    var projekt: Ref?
                    if let name = plan.projekt {
                        let item = catalog.projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                        projekt = Ref(id: item?.id ?? Catalog.newID(), name: item?.name ?? name)
                    }
                    // Neu angelegter Song muss gespeichert sein, bevor der Import ihn nachschlägt
                    try? await library.setCatalog(catalog)
                    let (id, ort) = try await ExportAnnahme.uebernimm(fund, attrs: a, projekt: projekt,
                                                                      herkunft: plan.herkunft, into: library)
                    if !records.contains(where: { $0.id == id }),
                       let r = try? await library.allRecords().first(where: { $0.id == id }) {
                        didImport(r)
                        neu[fund.begleitung.anzeigename, default: 0] += 1
                    }
                    ExportAnnahme.antworte(fund.begleitung, datei: fund.begleitung.datei, ok: true, id: id, ort: ort)
                } catch {
                    exportFailed.insert(p)
                    ExportAnnahme.antworte(fund.begleitung, datei: fund.begleitung.datei, ok: false,
                                           grund: error.localizedDescription)
                }
                refreshSpace()
            }
            if !neu.isEmpty {
                scheduleCacheSave()
                let note = neu.sorted { $0.key < $1.key }.map { "\($0.value) neu aus \($0.key)" }.joined(separator: " · ")
                inboxNote = note
                Task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if inboxNote == note { inboxNote = nil }
                }
            }
        }
    }

    /// Vom Link `archivn://zeigen?id=…`: großes Fenster auf, Video in seiner Song-Seite markiert
    func zeige(id: String, versuch: Int = 0) {
        AppDelegate.mainWanted = true
        if let show = AppDelegate.showMain { show() } else { WindowFinder.main?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if let r = records.first(where: { $0.id == id }) {
            reveal(r)
        } else if versuch < 10 {
            // Mediathek wird beim Start noch geöffnet
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.zeige(id: id, versuch: versuch + 1)
            }
        }
    }
}
