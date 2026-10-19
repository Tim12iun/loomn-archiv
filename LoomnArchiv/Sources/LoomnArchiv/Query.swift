import Foundation

/// Kombinierte Suche: Song + Art + Format + Mood, dazu Tags, Zeitraum und Freitext.
/// Innerhalb einer Gruppe reicht ein Treffer (Song A oder B), bei Moods und Tags müssen alle passen
/// („ruhig“ + „dunkel“ = beides). Gruppen werden immer kombiniert.
struct LibraryFilter: Equatable {
    var text = ""
    var songIDs: Set<String> = []
    var noSong = false
    var kindIDs: Set<String> = []
    var formatIDs: Set<String> = []
    var moodIDs: Set<String> = []
    var tags: Set<String> = []
    var from: Date?
    var to: Date?

    var isEmpty: Bool { self == LibraryFilter() }
    var activeCount: Int {
        [!text.trimmingCharacters(in: .whitespaces).isEmpty, !songIDs.isEmpty || noSong, !kindIDs.isEmpty,
         !formatIDs.isEmpty, !moodIDs.isEmpty, !tags.isEmpty, from != nil || to != nil].filter { $0 }.count
    }

    func matches(_ r: VideoRecord) -> Bool {
        if !songIDs.isEmpty || noSong {
            let ok = (noSong && r.songs.isEmpty) || r.songs.contains { songIDs.contains($0.id) }
            if !ok { return false }
        }
        if !kindIDs.isEmpty, !kindIDs.contains(r.kind.id) { return false }
        if !formatIDs.isEmpty, !formatIDs.contains(r.format.id) { return false }
        if !moodIDs.isEmpty {
            let have = Set(r.moods.map(\.id))
            if !moodIDs.isSubset(of: have) { return false }
        }
        if !tags.isEmpty {
            let have = Set(r.tags.map { $0.lowercased() })
            if !tags.allSatisfy({ have.contains($0.lowercased()) }) { return false }
        }
        if let from, r.createdAt < Calendar.current.startOfDay(for: from) { return false }
        if let to, let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)),
           r.createdAt >= end { return false }
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        if !words.isEmpty {
            let hay = r.searchText
            if !words.allSatisfy({ hay.contains($0) }) { return false }
        }
        return true
    }

    func apply(_ records: [VideoRecord]) -> [VideoRecord] {
        isEmpty ? records : records.filter(matches)
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case createdDesc, createdAsc, importedDesc
    var id: String { rawValue }
    var title: String {
        switch self {
        case .createdDesc: return "Entstanden, neueste zuerst"
        case .createdAsc: return "Entstanden, älteste zuerst"
        case .importedDesc: return "Zuletzt hinzugefügt"
        }
    }

    func sort(_ r: [VideoRecord]) -> [VideoRecord] {
        switch self {
        case .createdDesc: return r.sorted { $0.createdAt > $1.createdAt }
        case .createdAsc: return r.sorted { $0.createdAt < $1.createdAt }
        case .importedDesc: return r.sorted { $0.importedAt > $1.importedAt }
        }
    }
}
