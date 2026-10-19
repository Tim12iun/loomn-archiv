import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Loomn-Archiv-Schnittstelle · Version 1
///
/// Diese Datei ist in jedem Loomn-Tool und im Archiv WORTGLEICH. Nur über eine neue Fassung der
/// Übergabe „Archiv-Schnittstelle“ ändern, nie in einem einzelnen Tool. Regeln: Felder und Ordnernamen
/// nie umbenennen oder entfernen, nur neue optionale Felder ergänzen; unbekannte Felder werden ignoriert.
///
/// Ablauf: Ein Tool rendert ein Video und ruft `liefere(...)` auf. Das legt im gemeinsamen Ordner
/// `Loomn/Eingang/<id>/` das Video und eine `loomn.json` mit Art, Song, Format, Mood usw. ab.
/// Das Archiv übernimmt jede vollständige Lieferung automatisch, schreibt `Loomn/Quittungen/<id>.json`
/// und räumt den Eingang auf. Für die Auswahllisten (Songs, Formate, Moods) schreibt das Archiv
/// `Loomn/katalog.json`, die Tools lesen sie.
enum LoomnArchiv {
    static let schnittstelle = 1

    // MARK: - Gemeinsamer Ordner

    /// Mac: iCloud Drive/Loomn, ohne iCloud Drive ~/Documents/Loomn.
    /// iPhone: der Ordner, den man einmal über `merkeOrdner(_:)` gewählt hat (iCloud Drive/Loomn).
    static var ablage: URL? {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let basis = FileManager.default.fileExists(atPath: icloud.path)
            ? icloud : home.appendingPathComponent("Documents", isDirectory: true)
        return basis.appendingPathComponent("Loomn", isDirectory: true)
        #else
        guard let daten = UserDefaults.standard.data(forKey: lesezeichenSchluessel) else { return nil }
        var veraltet = false
        return try? URL(resolvingBookmarkData: daten, bookmarkDataIsStale: &veraltet)
        #endif
    }

    static var eingang: URL? { ablage?.appendingPathComponent("Eingang", isDirectory: true) }
    static var quittungen: URL? { ablage?.appendingPathComponent("Quittungen", isDirectory: true) }
    static var katalogDatei: URL? { ablage?.appendingPathComponent("katalog.json") }

    private static let lesezeichenSchluessel = "loomn.ablage.lesezeichen"

    /// iPhone: Ordner aus `.fileImporter(allowedContentTypes: [.folder])` dauerhaft merken.
    static func merkeOrdner(_ url: URL) {
        let zugriff = url.startAccessingSecurityScopedResource()
        defer { if zugriff { url.stopAccessingSecurityScopedResource() } }
        if let daten = try? url.bookmarkData() {
            UserDefaults.standard.set(daten, forKey: lesezeichenSchluessel)
        }
    }

    static var ordnerGewaehlt: Bool { ablage != nil }

    /// Führt `arbeit` mit Zugriff auf den gemeinsamen Ordner aus (auf dem iPhone nötig, auf dem Mac harmlos).
    static func mitZugriff<T>(_ arbeit: (URL) throws -> T) throws -> T {
        guard let ablage else { throw Fehler.keinOrdner }
        let zugriff = ablage.startAccessingSecurityScopedResource()
        defer { if zugriff { ablage.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: ablage, withIntermediateDirectories: true)
        return try arbeit(ablage)
    }

    // MARK: - Datenformat (loomn.json, katalog.json, Quittung)

    /// Die vier Arten wie im Archiv. In der JSON steht der Text ("RAW" …), damit spätere Arten alte Leser nicht brechen.
    enum Art: String, CaseIterable, Identifiable {
        case raw = "RAW", cut = "CUT", edit = "EDIT", final = "FINAL"
        var id: String { rawValue }
    }

    /// Technische Eckdaten des gelieferten Videos (nur zur Info fürs Archiv).
    struct Technik: Codable, Equatable {
        var breite: Int?
        var hoehe: Int?
        var bildrate: Double?
        var codec: String?
    }

    /// Inhalt von `Eingang/<id>/loomn.json`.
    struct Lieferung: Codable, Equatable {
        var schnittstelle: Int
        var id: String
        var werkzeug: String
        var werkzeugBuild: Int?
        var erstellt: Date
        /// Dateiname des Videos im selben Ordner
        var datei: String
        /// Größe in Bytes; das Archiv übernimmt erst, wenn die Datei so groß ist (iCloud-Sync)
        var groesse: Int64
        var art: String
        /// nil = ohne Song
        var song: String?
        var formate: [String]?
        var moods: [String]?
        var beschreibung: String?
        var tags: [String]?
        /// Archiv-IDs der Clips, aus denen dieses Video entstanden ist
        var herkunft: [String]?
        var technik: Technik?
    }

    /// Inhalt von `katalog.json`, vom Archiv geschrieben.
    struct Katalog: Codable, Equatable {
        var schnittstelle: Int
        var aktualisiert: Date?
        var songs: [String]?
        var formate: [String]?
        var moods: [String]?
        var tags: [String]?
    }

    /// Inhalt von `Quittungen/<id>.json`, vom Archiv geschrieben.
    struct Quittung: Codable, Equatable {
        var schnittstelle: Int
        var id: String
        /// "ok" oder "fehler"
        var status: String
        var meldung: String?
        var archivID: String?
        var zeit: Date?
    }

    /// Die Angaben, die man im Export-Fenster wählt (dieselben Pflichtfelder wie beim Import im Archiv).
    struct Angaben: Equatable {
        var art: Art = .edit
        var song: String?
        var ohneSong = false
        var formate: [String] = []
        var moods: [String] = []
        var beschreibung = ""
        var tags: [String] = []

        /// Was noch fehlt, in der Schreibweise des Archivs („Song, Format, Mood“)
        var fehlt: [String] {
            var liste: [String] = []
            if !ohneSong && (song ?? "").trimmingCharacters(in: .whitespaces).isEmpty { liste.append("Song") }
            if formate.isEmpty { liste.append("Format") }
            if moods.isEmpty { liste.append("Mood") }
            return liste
        }
        var vollstaendig: Bool { fehlt.isEmpty }
    }

    enum Fehler: LocalizedError {
        case keinOrdner
        case unvollstaendig([String])
        var errorDescription: String? {
            switch self {
            case .keinOrdner: return "Kein Loomn-Ordner gewählt."
            case .unvollstaendig(let fehlt): return "Noch offen: " + fehlt.joined(separator: ", ")
            }
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Tool-Seite

    /// Liefert ein fertig gerendertes Video ans Archiv. `video` wird verschoben (bei `kopieren` kopiert).
    /// `herkunft` sind die Eingangsdateien, die das Tool bearbeitet hat (z. B. aus dem Archiv gezogen).
    /// Gibt die Lieferungs-ID zurück, mit der man später `quittung(fuer:)` abfragen kann.
    @discardableResult
    static func liefere(video: URL, angaben: Angaben, werkzeug: String, werkzeugBuild: Int? = nil,
                        herkunft: [URL] = [], technik: Technik? = nil, kopieren: Bool = false) throws -> String {
        guard angaben.vollstaendig else { throw Fehler.unvollstaendig(angaben.fehlt) }
        return try mitZugriff { ablage in
            let fm = FileManager.default
            let eingang = ablage.appendingPathComponent("Eingang", isDirectory: true)
            try fm.createDirectory(at: eingang, withIntermediateDirectories: true)

            let id = UUID().uuidString
            // Erst unter verstecktem Namen fertig schreiben, dann in einem Schritt umbenennen:
            // so sieht das Archiv nie eine halbe Lieferung.
            let zwischen = eingang.appendingPathComponent(".\(id).entsteht", isDirectory: true)
            try fm.createDirectory(at: zwischen, withIntermediateDirectories: true)

            let name = video.lastPathComponent
            let ziel = zwischen.appendingPathComponent(name)
            if kopieren { try fm.copyItem(at: video, to: ziel) } else { try fm.moveItem(at: video, to: ziel) }
            let groesse = (try fm.attributesOfItem(atPath: ziel.path)[.size] as? NSNumber)?.int64Value ?? 0

            let song = angaben.ohneSong ? nil : angaben.song?.trimmingCharacters(in: .whitespaces)
            let beschreibung = angaben.beschreibung.trimmingCharacters(in: .whitespacesAndNewlines)
            let lieferung = Lieferung(
                schnittstelle: schnittstelle, id: id, werkzeug: werkzeug, werkzeugBuild: werkzeugBuild,
                erstellt: Date(), datei: name, groesse: groesse, art: angaben.art.rawValue,
                song: song, formate: angaben.formate, moods: angaben.moods,
                beschreibung: beschreibung.isEmpty ? nil : beschreibung,
                tags: angaben.tags.isEmpty ? nil : Array(angaben.tags.prefix(3)),
                herkunft: herkunft.compactMap(archivID(von:)), technik: technik)
            try encoder.encode(lieferung).write(to: zwischen.appendingPathComponent("loomn.json"), options: .atomic)

            try fm.moveItem(at: zwischen, to: eingang.appendingPathComponent(id, isDirectory: true))
            return id
        }
    }

    /// Katalog des Archivs für die Auswahllisten; nil, wenn das Archiv noch nie gelaufen ist.
    static func leseKatalog() -> Katalog? {
        try? mitZugriff { ablage in
            let daten = try Data(contentsOf: ablage.appendingPathComponent("katalog.json"))
            return try decoder.decode(Katalog.self, from: daten)
        }
    }

    /// Quittung des Archivs zu einer Lieferung; nil, solange das Archiv sie noch nicht übernommen hat.
    static func quittung(fuer id: String) -> Quittung? {
        try? mitZugriff { ablage in
            let datei = ablage.appendingPathComponent("Quittungen/\(id).json")
            return try decoder.decode(Quittung.self, from: Data(contentsOf: datei))
        }
    }

    // MARK: - Herkunft über Datei-Attribute

    /// Das Archiv markiert seine Videos mit ID und Song. Die Markierung reist beim Ziehen und Kopieren mit,
    /// so weiß ein Tool, woher ein Clip stammt, und kann den Song vorbelegen.
    static let idAttribut = "de.loomn.archiv.id"
    static let songAttribut = "de.loomn.archiv.song"

    static func archivID(von url: URL) -> String? { leseAttribut(idAttribut, url) }
    static func song(von url: URL) -> String? { leseAttribut(songAttribut, url) }

    /// Archiv-Seite: Video in der Mediathek markieren.
    static func markiere(_ url: URL, archivID: String, song: String?) {
        schreibeAttribut(idAttribut, archivID, url)
        if let song { schreibeAttribut(songAttribut, song, url) } else { removexattr(url.path, songAttribut, 0) }
    }

    private static func leseAttribut(_ name: String, _ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { pfad -> String? in
            guard let pfad else { return nil }
            let laenge = getxattr(pfad, name, nil, 0, 0, 0)
            guard laenge > 0 else { return nil }
            var daten = [UInt8](repeating: 0, count: laenge)
            let gelesen = getxattr(pfad, name, &daten, laenge, 0, 0)
            guard gelesen > 0 else { return nil }
            return String(decoding: daten.prefix(gelesen), as: UTF8.self)
        }
    }

    private static func schreibeAttribut(_ name: String, _ wert: String, _ url: URL) {
        url.withUnsafeFileSystemRepresentation { pfad in
            guard let pfad else { return }
            let daten = Array(wert.utf8)
            _ = setxattr(pfad, name, daten, daten.count, 0, 0)
        }
    }

    // MARK: - Archiv-Seite

    struct Fund {
        var ordner: URL
        var video: URL
        var lieferung: Lieferung
    }

    /// Alle vollständig angekommenen Lieferungen im Eingang (auch von neueren Schnittstellen-Versionen:
    /// bekannte Felder werden gelesen, unbekannte ignoriert). Noch nicht fertig synchronisierte bleiben liegen.
    static func offeneLieferungen() -> [Fund] {
        (try? mitZugriff { ablage -> [Fund] in
            let fm = FileManager.default
            let eingang = ablage.appendingPathComponent("Eingang", isDirectory: true)
            let ordner = (try? fm.contentsOfDirectory(at: eingang, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])) ?? []
            return ordner.compactMap { ordner -> Fund? in
                let json = ordner.appendingPathComponent("loomn.json")
                guard let daten = try? Data(contentsOf: json),
                      let lieferung = try? decoder.decode(Lieferung.self, from: daten) else {
                    try? fm.startDownloadingUbiquitousItem(at: json)
                    return nil
                }
                let video = ordner.appendingPathComponent(lieferung.datei)
                let groesse = (try? fm.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.int64Value
                guard groesse == lieferung.groesse else {
                    try? fm.startDownloadingUbiquitousItem(at: video)
                    return nil
                }
                return Fund(ordner: ordner, video: video, lieferung: lieferung)
            }
            .sorted { $0.lieferung.erstellt < $1.lieferung.erstellt }
        }) ?? []
    }

    /// Nach der Übernahme: Quittung schreiben und den Lieferungsordner entfernen.
    /// Bei einem Fehler bleibt die Lieferung liegen, damit nichts verloren geht.
    static func erledige(_ fund: Fund, archivID: String?, fehler: String? = nil) {
        try? mitZugriff { ablage in
            let fm = FileManager.default
            let ordner = ablage.appendingPathComponent("Quittungen", isDirectory: true)
            try fm.createDirectory(at: ordner, withIntermediateDirectories: true)
            let quittung = Quittung(schnittstelle: schnittstelle, id: fund.lieferung.id,
                                    status: fehler == nil ? "ok" : "fehler", meldung: fehler,
                                    archivID: archivID, zeit: Date())
            try encoder.encode(quittung).write(to: ordner.appendingPathComponent("\(fund.lieferung.id).json"),
                                               options: .atomic)
            if fehler == nil { try? fm.removeItem(at: fund.ordner) }
        }
    }

    /// Archiv-Seite: Auswahllisten für die Tools veröffentlichen (bei jeder Änderung an Songs, Formaten, Moods).
    static func schreibeKatalog(songs: [String], formate: [String], moods: [String], tags: [String]) {
        try? mitZugriff { ablage in
            let katalog = Katalog(schnittstelle: schnittstelle, aktualisiert: Date(),
                                  songs: songs, formate: formate, moods: moods, tags: tags)
            try encoder.encode(katalog).write(to: ablage.appendingPathComponent("katalog.json"), options: .atomic)
        }
    }
}
