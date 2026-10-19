import Foundation

// Datenmodell des Archivs. Alles hier ist auf Jahre angelegt:
// - Listen (Art, Format, Mood, Song) haben feste IDs; Umbenennen ändert nur den Anzeigenamen.
// - Begleitdateien speichern IDs plus Klartext, damit sie auch ohne Katalog lesbar bleiben.
// - Unbekannte Felder aus neueren Versionen (oder später aus Loomn Cam) bleiben beim Speichern erhalten.

// MARK: - Beliebiges JSON (für unbekannte Felder und Fremd-Metadaten)

enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
}

// MARK: - Verweise in der Begleitdatei (ID + Klartext)

struct Ref: Codable, Hashable {
    var id: String
    var name: String
}

struct SongRef: Codable, Hashable {
    var id: String
    var title: String
    var artist: String?
}

struct Post: Codable, Hashable {
    var date: Date
    var platform: String
    var caption: String
}

struct MediaInfo: Codable, Hashable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var codec: String?
}

// MARK: - Ein Video im Archiv (= Inhalt der Begleitdatei name.loomn.json)

struct VideoRecord: Codable, Identifiable, Equatable {
    static let schemaVersion = 1

    var schema = VideoRecord.schemaVersion
    var id: String
    /// Dateiname des Videos (liegt im selben Ordner wie die Begleitdatei)
    var file: String
    var originalName: String
    var sha256: String
    var size: Int64
    /// Entstehungstag: Aufnahmedatum aus den Metadaten, sonst Erstelldatum der Datei
    var createdAt: Date
    var createdAtSource: String
    var importedAt: Date
    var kind: Ref
    /// leer = „ohne Song“
    var songs: [SongRef]
    var format: Ref
    var moods: [Ref]
    var description: String
    var tags: [String]
    var project: Ref?
    var notes: String
    var posts: [Post]
    var media: MediaInfo?
    /// Herkunft, z. B. Metadaten aus Loomn Cam (`loomnTake`). Für spätere Anbindung, ohne Umbau.
    var source: [String: JSONValue]?

    /// Pfad relativ zur Mediathek (nicht in der Datei gespeichert, ergibt sich aus dem Ablageort)
    var relPath: String = ""

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, id, file, originalName, sha256, size, createdAt, createdAtSource, importedAt
        case kind, songs, format, moods, description, tags, project, notes, posts, media, source
    }

    init(id: String, file: String, originalName: String, sha256: String, size: Int64, createdAt: Date,
         createdAtSource: String, importedAt: Date, kind: Ref, songs: [SongRef], format: Ref, moods: [Ref],
         description: String = "", tags: [String] = [], project: Ref? = nil, notes: String = "",
         posts: [Post] = [], media: MediaInfo? = nil, source: [String: JSONValue]? = nil) {
        self.id = id; self.file = file; self.originalName = originalName; self.sha256 = sha256; self.size = size
        self.createdAt = createdAt; self.createdAtSource = createdAtSource; self.importedAt = importedAt
        self.kind = kind; self.songs = songs; self.format = format; self.moods = moods
        self.description = description; self.tags = tags; self.project = project; self.notes = notes
        self.posts = posts; self.media = media; self.source = source
    }

    /// Tolerant lesen: fehlende Felder bekommen Standardwerte, damit auch ältere oder
    /// von Hand bearbeitete Begleitdateien geöffnet werden.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        id = try c.decode(String.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName) ?? file
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        createdAtSource = try c.decodeIfPresent(String.self, forKey: .createdAtSource) ?? "file"
        importedAt = try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? createdAt
        kind = try c.decodeIfPresent(Ref.self, forKey: .kind) ?? Ref(id: Kind.raw, name: "RAW")
        songs = try c.decodeIfPresent([SongRef].self, forKey: .songs) ?? []
        format = try c.decodeIfPresent(Ref.self, forKey: .format) ?? Ref(id: "", name: "")
        moods = try c.decodeIfPresent([Ref].self, forKey: .moods) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        project = try c.decodeIfPresent(Ref.self, forKey: .project)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        posts = try c.decodeIfPresent([Post].self, forKey: .posts) ?? []
        media = try c.decodeIfPresent(MediaInfo.self, forKey: .media)
        source = try c.decodeIfPresent([String: JSONValue].self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(file, forKey: .file)
        try c.encode(originalName, forKey: .originalName)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(size, forKey: .size)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(createdAtSource, forKey: .createdAtSource)
        try c.encode(importedAt, forKey: .importedAt)
        try c.encode(kind, forKey: .kind)
        try c.encode(songs, forKey: .songs)
        try c.encode(format, forKey: .format)
        try c.encode(moods, forKey: .moods)
        try c.encode(description, forKey: .description)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(project, forKey: .project)
        try c.encode(notes, forKey: .notes)
        try c.encode(posts, forKey: .posts)
        try c.encodeIfPresent(media, forKey: .media)
        try c.encodeIfPresent(source, forKey: .source)
    }

    var noSong: Bool { songs.isEmpty }
    var songTitle: String { songs.isEmpty ? "ohne Song" : songs.map(\.title).joined(separator: ", ") }
    /// Pfad der Begleitdatei relativ zur Mediathek
    var sidecarRelPath: String { Sidecar.sidecarPath(forVideo: relPath) }

    /// Alles, was die Freitextsuche durchsucht (klein geschrieben).
    var searchText: String {
        var parts = [songTitle, songs.compactMap(\.artist).joined(separator: " "), kind.name, format.name,
                     moods.map(\.name).joined(separator: " "), description, tags.joined(separator: " "),
                     project?.name ?? "", notes, file, originalName]
        parts += posts.map { "\($0.platform) \($0.caption)" }
        return parts.joined(separator: " ").lowercased()
    }
}

// MARK: - Begleitdatei lesen/schreiben (unbekannte Felder bleiben erhalten)

enum Sidecar {
    static let suffix = ".loomn.json"

    static func sidecarPath(forVideo path: String) -> String {
        let ns = path as NSString
        return ns.deletingPathExtension + suffix
    }

    static func url(forVideo url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("loomn.json")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self), let date = parseDate(s) { return date }
            if let t = try? c.decode(Double.self) { return Date(timeIntervalSince1970: t) }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Datum unlesbar")
        }
        return d
    }()

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func read(_ url: URL) throws -> VideoRecord {
        try decoder.decode(VideoRecord.self, from: Data(contentsOf: url))
    }

    /// Schreibt den Datensatz. Felder, die diese Version nicht kennt, werden aus der
    /// vorhandenen Datei übernommen statt gelöscht.
    static func write(_ record: VideoRecord, to url: URL) throws {
        var merged: [String: JSONValue] = [:]
        if let old = try? Data(contentsOf: url),
           let raw = try? decoder.decode([String: JSONValue].self, from: old) {
            merged = raw
        }
        let known = Set(VideoRecord.CodingKeys.allCases.map(\.rawValue))
        for k in known { merged.removeValue(forKey: k) }
        let mine = try decoder.decode([String: JSONValue].self, from: encoder.encode(record))
        merged.merge(mine) { _, new in new }
        try atomicWrite(encoder.encode(merged), to: url)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Katalog: die pflegbaren Listen (liegt in der Mediathek auf der SSD)

enum Kind {
    static let raw = "raw", cut = "cut", edit = "edit", final = "final"
}

struct ListItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var detail: String?
    var hidden: Bool = false
    var order: Int = 0

    init(id: String = Catalog.newID(), name: String, detail: String? = nil, hidden: Bool = false, order: Int = 0) {
        self.id = id; self.name = name; self.detail = detail; self.hidden = hidden; self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
}

struct SongItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String?
    var hidden: Bool = false
    var created: Date?
    /// Audiodateien des Songs, älteste zuerst. Liegen unverändert unter Songs/ in der Mediathek.
    var versions: [SongVersion] = []
    var currentVersionID: String?

    init(id: String = Catalog.newID(), title: String, artist: String? = nil, hidden: Bool = false, created: Date? = Date()) {
        self.id = id; self.title = title; self.artist = artist; self.hidden = hidden; self.created = created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created)
        versions = try c.decodeIfPresent([SongVersion].self, forKey: .versions) ?? []
        currentVersionID = try c.decodeIfPresent(String.self, forKey: .currentVersionID)
    }

    /// Aktuelle Version: die markierte, sonst die neueste
    var current: SongVersion? { versions.first { $0.id == currentVersionID } ?? versions.last }
    var hasAudio: Bool { !versions.isEmpty }

    var ref: SongRef { SongRef(id: id, title: title, artist: artist?.isEmpty == true ? nil : artist) }
    /// Künstler wird nicht mehr gezeigt (alte Einträge behalten ihn nur in der Datei)
    var display: String { title }
}

/// Eine hochgeladene Audiodatei eines Songs.
struct SongVersion: Codable, Identifiable, Hashable {
    var id: String
    var number: Int
    /// Pfad relativ zur Mediathek, z. B. Songs/Nachtfahrt_ab12/Nachtfahrt_v2_2026-10-19.wav
    var file: String
    var originalName: String
    var sha256: String
    var size: Int64
    var added: Date
    var duration: Double?
}

/// Zuletzt benutzte Import-Angaben (damit eine Serie vom selben Dreh nur Enter braucht).
struct ImportDefaults: Codable, Equatable {
    var kindID: String?
    var songIDs: [String]?
    var formatID: String?
    var moodIDs: [String] = []
    var description: String = ""
    var tags: [String] = []
}

struct Catalog: Codable, Equatable {
    static let schemaVersion = 1

    var schema = Catalog.schemaVersion
    var kinds: [ListItem]
    var formats: [ListItem]
    var moods: [ListItem]
    var songs: [SongItem]
    /// Freie Tags, zuletzt benutzte zuerst
    var tags: [String]
    var projects: [ListItem]
    var lastImport: ImportDefaults
    /// Stand der Vorgabe-Listen (2: drei Start-Moods, Splitscreen; 3: vier Start-Formate; 4: kein Ausblenden mehr)
    var defaultsVersion = Catalog.currentDefaults

    static let currentDefaults = 4
    static func newID() -> String { UUID().uuidString.lowercased() }

    static let defaultKinds: [ListItem] = [
        ListItem(id: Kind.raw, name: "RAW", detail: "Rohmaterial, unbearbeitet", order: 0),
        ListItem(id: Kind.cut, name: "CUT", detail: "Bearbeitet, nur geschnitten", order: 1),
        ListItem(id: Kind.edit, name: "EDIT", detail: "Geschnitten und mit Effekten", order: 2),
        ListItem(id: Kind.final, name: "FINAL", detail: "Fertiges Reel", order: 3),
    ]
    static let defaultFormats = ["Slow-Mo", "Zoom-out", "Splitscreen", "Stutter"]
    /// Frühere Vorgabe-Formate, die beim Umstieg ausgeblendet werden, solange kein Video sie trägt
    static let retiredFormats = ["Zoom-in", "Performance", "B-Roll", "Lyric"]
    static let defaultMoods = ["ruhig", "energetisch", "dunkel"]
    /// Frühere Vorgabe-Moods, die beim Umstieg ausgeblendet werden, solange kein Video sie trägt
    static let retiredMoods = ["warm", "melancholisch", "verträumt", "roh", "euphorisch"]

    static func makeDefault() -> Catalog {
        Catalog(kinds: defaultKinds,
                formats: defaultFormats.enumerated().map { ListItem(name: $1, order: $0) },
                moods: defaultMoods.enumerated().map { ListItem(name: $1, order: $0) },
                songs: [], tags: [], projects: [], lastImport: ImportDefaults(kindID: Kind.raw))
    }

    init(kinds: [ListItem], formats: [ListItem], moods: [ListItem], songs: [SongItem], tags: [String],
         projects: [ListItem], lastImport: ImportDefaults) {
        self.kinds = kinds; self.formats = formats; self.moods = moods; self.songs = songs
        self.tags = tags; self.projects = projects; self.lastImport = lastImport
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        kinds = try c.decodeIfPresent([ListItem].self, forKey: .kinds) ?? Catalog.defaultKinds
        formats = try c.decodeIfPresent([ListItem].self, forKey: .formats) ?? []
        moods = try c.decodeIfPresent([ListItem].self, forKey: .moods) ?? []
        songs = try c.decodeIfPresent([SongItem].self, forKey: .songs) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        projects = try c.decodeIfPresent([ListItem].self, forKey: .projects) ?? []
        lastImport = try c.decodeIfPresent(ImportDefaults.self, forKey: .lastImport) ?? ImportDefaults(kindID: Kind.raw)
        defaultsVersion = try c.decodeIfPresent(Int.self, forKey: .defaultsVersion) ?? 1
        // Grundarten immer vorhanden
        for k in Catalog.defaultKinds where !kinds.contains(where: { $0.id == k.id }) { kinds.append(k) }
    }

    // Sichtbare Listen in Reihenfolge
    var visibleKinds: [ListItem] { kinds.filter { !$0.hidden }.sorted { $0.order < $1.order } }
    var visibleFormats: [ListItem] { formats.filter { !$0.hidden }.sorted { $0.order < $1.order } }
    var visibleMoods: [ListItem] { moods.filter { !$0.hidden }.sorted { $0.order < $1.order } }
    var visibleSongs: [SongItem] { songs.filter { !$0.hidden }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }

    func kind(_ id: String?) -> ListItem? { kinds.first { $0.id == id } }
    func format(_ id: String?) -> ListItem? { formats.first { $0.id == id } }
    func mood(_ id: String) -> ListItem? { moods.first { $0.id == id } }
    func song(_ id: String) -> SongItem? { songs.first { $0.id == id } }

    /// Song per Titel finden (ohne Rücksicht auf Groß-/Kleinschreibung) oder neu anlegen.
    @discardableResult
    mutating func songNamed(_ title: String, artist: String? = nil) -> SongItem {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = songs.first(where: { $0.title.compare(t, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            if s.hidden, let i = songs.firstIndex(of: s) { songs[i].hidden = false; return songs[i] }
            return s
        }
        let s = SongItem(title: t, artist: artist)
        songs.append(s)
        return s
    }

    @discardableResult
    mutating func addFormat(_ name: String) -> ListItem { Catalog.add(name, to: &formats) }
    @discardableResult
    mutating func addMood(_ name: String) -> ListItem { Catalog.add(name, to: &moods) }

    private static func add(_ name: String, to list: inout [ListItem]) -> ListItem {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = list.firstIndex(where: { $0.name.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            list[i].hidden = false
            return list[i]
        }
        let item = ListItem(name: n, order: (list.map(\.order).max() ?? -1) + 1)
        list.append(item)
        return item
    }

    /// Ältere Mediathek auf die aktuellen Vorgaben bringen. Nichts wird gelöscht: nicht benutzte
    /// alte Moods werden nur ausgeblendet (in den Einstellungen wieder einblendbar).
    mutating func upgradeDefaults(usedMoodIDs: Set<String>, usedFormatIDs: Set<String> = [], usedSongIDs: Set<String> = []) -> Bool {
        guard defaultsVersion < Catalog.currentDefaults else { return false }
        if defaultsVersion < 2 {
            for i in moods.indices where Catalog.retiredMoods.contains(moods[i].name) && !usedMoodIDs.contains(moods[i].id) {
                moods[i].hidden = true
            }
            if !formats.contains(where: { $0.name.caseInsensitiveCompare("Splitscreen") == .orderedSame }) {
                addFormat("Splitscreen")
            }
        }
        if defaultsVersion < 3 {
            for i in formats.indices where Catalog.retiredFormats.contains(formats[i].name) && !usedFormatIDs.contains(formats[i].id) {
                formats[i].hidden = true
            }
            if !formats.contains(where: { $0.name.caseInsensitiveCompare("Slow-Mo") == .orderedSame }) { addFormat("Slow-Mo") }
            for i in formats.indices where formats[i].name == "Slow-Mo" { formats[i].hidden = false }
        }
        if defaultsVersion < 4 {
            // Kein Ausblenden mehr: Einträge sind da oder gelöscht. Benutzte kommen zurück, ungenutzte gehen.
            formats.removeAll { $0.hidden && !usedFormatIDs.contains($0.id) }
            moods.removeAll { $0.hidden && !usedMoodIDs.contains($0.id) }
            songs.removeAll { $0.hidden && !usedSongIDs.contains($0.id) }
            for i in formats.indices { formats[i].hidden = false }
            for i in moods.indices { moods[i].hidden = false }
            for i in songs.indices { songs[i].hidden = false }
        }
        defaultsVersion = Catalog.currentDefaults
        return true
    }

    mutating func removeFormat(_ id: String) { formats.removeAll { $0.id == id } }
    mutating func removeMood(_ id: String) { moods.removeAll { $0.id == id } }
    mutating func removeSong(_ id: String) { songs.removeAll { $0.id == id } }
    mutating func removeTag(_ t: String) { tags.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame } }

    mutating func noteTags(_ used: [String]) {
        for t in used.reversed() {
            tags.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
            tags.insert(t, at: 0)
        }
    }

    /// Einträge ergänzen, die in Begleitdateien vorkommen, im Katalog aber fehlen
    /// (z. B. nach Verlust des Katalogs). Vorhandene Namen bleiben unverändert.
    mutating func absorb(_ r: VideoRecord) {
        if !r.kind.id.isEmpty, kind(r.kind.id) == nil {
            kinds.append(ListItem(id: r.kind.id, name: r.kind.name, order: (kinds.map(\.order).max() ?? 0) + 1))
        }
        if !r.format.id.isEmpty, format(r.format.id) == nil {
            formats.append(ListItem(id: r.format.id, name: r.format.name, order: (formats.map(\.order).max() ?? -1) + 1))
        }
        for m in r.moods where mood(m.id) == nil {
            moods.append(ListItem(id: m.id, name: m.name, order: (moods.map(\.order).max() ?? -1) + 1))
        }
        for s in r.songs where song(s.id) == nil {
            songs.append(SongItem(id: s.id, title: s.title, artist: s.artist, created: r.importedAt))
        }
        for t in r.tags where !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { tags.append(t) }
        if let p = r.project, !projects.contains(where: { $0.id == p.id }) { projects.append(ListItem(id: p.id, name: p.name)) }
    }

    /// Klartext eines Datensatzes auf die aktuellen Anzeigenamen bringen.
    func refresh(_ r: VideoRecord) -> VideoRecord {
        var r = r
        if let k = kind(r.kind.id) { r.kind.name = k.name }
        if let f = format(r.format.id) { r.format.name = f.name }
        r.moods = r.moods.map { m in mood(m.id).map { Ref(id: $0.id, name: $0.name) } ?? m }
        r.songs = r.songs.map { s in song(s.id)?.ref ?? s }
        return r
    }
}

// MARK: - Angaben zu einem Video (beim Import und beim Bearbeiten)

struct Attrs: Equatable {
    var kindID: String?
    /// nil = noch nicht gewählt, [] = „ohne Song“
    var songIDs: [String]?
    var formatID: String?
    var moodIDs: [String] = []
    var description: String = ""
    var tags: [String] = []
    var notes: String = ""

    var complete: Bool { kindID != nil && !(songIDs ?? []).isEmpty && formatID != nil && !moodIDs.isEmpty }

    var missing: [String] {
        var m: [String] = []
        if kindID == nil { m.append("Art") }
        if (songIDs ?? []).isEmpty { m.append("Song") }
        if formatID == nil { m.append("Format") }
        if moodIDs.isEmpty { m.append("Mood") }
        return m
    }

    /// Felder, in denen sich die Videos unterscheiden
    static func differing(_ list: [Attrs]) -> [String] {
        guard list.count > 1 else { return [] }
        func differs<T: Hashable>(_ f: (Attrs) -> T) -> Bool { Set(list.map(f)).count > 1 }
        var out: [String] = []
        if differs(\.kindID) { out.append("Art") }
        if differs({ $0.songIDs?.first }) { out.append("Song") }
        if differs(\.formatID) { out.append("Format") }
        if differs({ Set($0.moodIDs) }) { out.append("Mood") }
        if differs(\.description) { out.append("Beschreibung") }
        if differs({ Set($0.tags) }) { out.append("Tags") }
        return out
    }

    init(kindID: String? = nil, songIDs: [String]? = nil, formatID: String? = nil, moodIDs: [String] = [],
         description: String = "", tags: [String] = [], notes: String = "") {
        self.kindID = kindID; self.songIDs = songIDs; self.formatID = formatID; self.moodIDs = moodIDs
        self.description = description; self.tags = tags; self.notes = notes
    }

    init(_ r: VideoRecord) {
        kindID = r.kind.id
        songIDs = r.songs.map(\.id)
        formatID = r.format.id
        moodIDs = r.moods.map(\.id)
        description = r.description
        tags = r.tags
        notes = r.notes
    }

    /// Angaben in einen Datensatz übernehmen (mit Klartext aus dem Katalog).
    func apply(to r: inout VideoRecord, catalog: Catalog) {
        if let k = kindID, let item = catalog.kind(k) { r.kind = Ref(id: item.id, name: item.name) }
        if let s = songIDs { r.songs = s.compactMap { catalog.song($0)?.ref } }
        if let f = formatID, let item = catalog.format(f) { r.format = Ref(id: item.id, name: item.name) }
        r.moods = moodIDs.compactMap { catalog.mood($0).map { Ref(id: $0.id, name: $0.name) } }
        r.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        r.tags = tags
        r.notes = notes
    }
}
