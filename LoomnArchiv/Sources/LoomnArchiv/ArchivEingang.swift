import Foundation

/// Archiv-Seite der Tool-Schnittstelle (`LoomnArchivSchnittstelle.swift`): Katalog für die Tools
/// veröffentlichen, Lieferungen aus `Loomn/Eingang` ohne Nachfrage übernehmen, Videos markieren.
extension AppModel {
    /// Songs, Formate, Moods und Tags für die Auswahllisten der Tools (nur bei offener Mediathek)
    func publishCatalog() {
        guard online, Screenshots.requested == nil else { return }
        let c = catalog
        let songs = c.visibleSongs.map(\.title)
        let formate = c.visibleFormats.map(\.name)
        let moods = c.visibleMoods.map(\.name)
        let tags = c.tags
        Task.detached(priority: .utility) {
            LoomnArchiv.schreibeKatalog(songs: songs, formate: formate, moods: moods, tags: tags)
        }
    }

    /// Videodateien mit Archiv-ID und Song markieren; die Markierung reist beim Rausziehen mit.
    func markAll(_ list: [VideoRecord]) {
        guard let library else { return }
        let items = list.map { (library.paths.url($0.relPath), $0.id, $0.songs.first?.title) }
        Task.detached(priority: .background) {
            for (url, id, song) in items where FileManager.default.fileExists(atPath: url.path) {
                if LoomnArchiv.archivID(von: url) != id || LoomnArchiv.song(von: url) != song {
                    LoomnArchiv.markiere(url, archivID: id, song: song)
                }
            }
        }
    }

    /// Song-Audio zum Rausziehen: trägt den Song als Datei-Attribut (wie die Videos), aber bewusst
    /// keine Archiv-ID, damit eine spätere Lieferung nicht als neue Fassung eines Videos gilt.
    func songDragItem(_ s: SongItem, version: SongVersion? = nil) -> NSItemProvider {
        guard online, let v = version ?? s.current, let url = audioURL(v) else { return NSItemProvider() }
        url.withUnsafeFileSystemRepresentation { pfad in
            guard let pfad else { return }
            let daten = Array(s.title.utf8)
            _ = setxattr(pfad, LoomnArchiv.songAttribut, daten, daten.count, 0, 0)
        }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    /// Eingang prüfen (beim Start und alle 5 Sekunden). Ohne SSD bleibt alles liegen.
    func checkInbox() {
        guard online, !inboxRunning, library != nil, Screenshots.requested == nil else { return }
        inboxRunning = true
        Task {
            defer { inboxRunning = false }
            let failed = inboxFailed
            let funde = await Task.detached(priority: .utility) {
                LoomnArchiv.offeneLieferungen().filter { !failed.contains($0.lieferung.id) }
            }.value
            guard !funde.isEmpty else { return }
            var neu: [String: Int] = [:]
            for fund in funde {
                guard online, let library else { return }
                let l = fund.lieferung
                do {
                    let angaben = await attrs(for: l)
                    var extra: [String: JSONValue] = ["werkzeug": .string(l.werkzeug)]
                    if let h = l.herkunft, !h.isEmpty { extra["herkunft"] = .array(h.map { .string($0) }) }
                    let res = try await Importer.importFile(fund.video, sha: nil, attrs: angaben, into: library, source: extra)
                    let id: String
                    switch res {
                    case .imported(let r):
                        didImport(r)
                        id = r.id
                        neu[l.werkzeug, default: 0] += 1
                    case .duplicate(let existing):
                        id = existing
                    }
                    await Task.detached { LoomnArchiv.erledige(fund, archivID: id) }.value
                } catch {
                    inboxFailed.insert(l.id)
                    let text = error.localizedDescription
                    await Task.detached { LoomnArchiv.erledige(fund, archivID: nil, fehler: text) }.value
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

    /// Angaben einer Lieferung in Archiv-Angaben übersetzen. Unbekanntes wird angelegt wie beim Eintippen.
    private func attrs(for l: LoomnArchiv.Lieferung) async -> Attrs {
        var a = Attrs()
        a.kindID = catalog.kinds.first { $0.name.caseInsensitiveCompare(l.art) == .orderedSame }?.id ?? Kind.edit
        if let s = l.song?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            // „Nachtfahrt · LION“ → „Nachtfahrt“
            let title = s.components(separatedBy: " · ").first ?? s
            a.songIDs = newSong(title).map { [$0.id] } ?? []
        } else {
            a.songIDs = []
        }
        a.formatID = l.formate?.first.flatMap { newFormat($0) }?.id
        a.moodIDs = (l.moods ?? []).compactMap { newMood($0)?.id }
        a.description = l.beschreibung ?? ""
        a.tags = Array((l.tags ?? []).prefix(3))
        if !a.tags.isEmpty { let t = a.tags; updateCatalog { $0.noteTags(t) } }
        // Neu angelegte Einträge müssen gespeichert sein, bevor der Import sie nachschlägt
        if let library { try? await library.setCatalog(catalog) }
        return a
    }
}
