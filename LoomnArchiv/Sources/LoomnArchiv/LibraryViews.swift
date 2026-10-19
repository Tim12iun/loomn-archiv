import AppKit
import AVKit
import SwiftUI

// MARK: - Oben: Drop-Feld (immer sichtbar)

struct DropStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let ready = model.online || !model.hasLibrary
        // Klick öffnet das Importfenster leer: Videos dazuziehen oder nur einen Song anlegen
        Button { model.openImport() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: ready ? "square.and.arrow.down.on.square" : "externaldrive.badge.xmark")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(ready ? DS.accent : DS.amber)
                    Text(ready ? "Videos hierher ziehen" : "SSD anschließen").font(DS.font(19, .bold)).lineLimit(1)
                }
                // Nur wenn etwas fehlt, eine kurze Zeile
                if model.hasLibrary, !model.online {
                    Text("„\(model.rememberedVolume)“ fehlt").font(DS.font(14)).foregroundStyle(DS.amber)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface.opacity(0.5), in: DS.shape)
            .overlay(DS.shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])).foregroundStyle(ready ? DS.accent.opacity(0.6) : DS.amber))
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
    }
}

// MARK: - Links: Songs

struct SongSidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: ToolUpdater
    @State private var query = ""
    @State private var renaming: SongItem?
    @State private var newTitle = ""

    var body: some View {
        let songs = model.songsByActivity.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let counts = songCounts
        VStack(spacing: DS.gap) {
            DropStrip()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dim)
                TextField("Song suchen …", text: $query).textFieldStyle(.plain).font(DS.controlFont)
            }
            .padding(.horizontal, 10)
            .frame(height: DS.control)
            .background(DS.surface, in: DS.shape)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        entry("Alle Videos", count: model.records.count, active: model.page == .all && model.sort != .importedDesc, big: false) {
                            model.page = .all; model.sort = .createdDesc
                        }
                        // Nochmal klicken wählt ab, dann wieder „Alle Videos“
                        entry("Zuletzt hinzugefügt", count: nil, active: model.page == .all && model.sort == .importedDesc, big: false) {
                            let on = model.page == .all && model.sort == .importedDesc
                            model.page = .all; model.sort = on ? .createdDesc : .importedDesc
                        }
                        Text("Songs").dsLabel().padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                    }
                    ForEach(songs) { s in
                        entry(s.title, count: counts[s.id] ?? 0, active: model.page == .song(s.id), big: true) {
                            model.page = model.page == .song(s.id) ? .all : .song(s.id)
                        }
                        // Rechtsklick: umbenennen oder löschen (die Songs werden nur hier verwaltet)
                        .contextMenu {
                            Button("Umbenennen …") { newTitle = s.title; renaming = s }
                            Button("Löschen …") {
                                confirmDelete(name: s.title, entry: .song(s.id), what: "einen Song",
                                              options: model.catalog.visibleSongs.filter { $0.id != s.id }.map { ($0.id, $0.title) },
                                              model: model)
                            }
                        }
                    }
                    // Nur für ältere Videos ohne Song; neue brauchen immer einen Song
                    if model.records.contains(where: \.noSong), query.isEmpty || "ohne song".contains(query.lowercased()) {
                        entry("ohne Song", count: model.records.filter(\.noSong).count, active: model.page == .noSong, big: true) {
                            model.page = model.page == .noSong ? .all : .noSong
                        }
                        .opacity(0.8)
                    }
                    if songs.isEmpty && !query.isEmpty {
                        Text("Kein Song „\(query)“").font(DS.font(16)).foregroundStyle(DS.dim).padding(10)
                    }
                }
                .padding(.bottom, DS.gap)
            }
            // Versionszeile: Klick sucht nach Updates
            Button {
                model.settingsTab = 5
                model.showSettings = true
                updater.check(manual: true)
            } label: {
                Text("Version \(updater.currentVersion) · Build \(updater.currentBuild)").dsLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Nach Updates suchen")
        }
        .padding([.horizontal, .top], DS.gap)
        .background(DS.surface.opacity(0.35))
        .alert("Song umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titel", text: $newTitle)
            Button("Umbenennen") { rename() }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
    }

    private func rename() {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = renaming, !t.isEmpty, t != s.title else { renaming = nil; return }
        if model.catalog.songs.contains(where: { $0.id != s.id && $0.title.caseInsensitiveCompare(t) == .orderedSame }) {
            model.message = "Den Song „\(t)“ gibt es schon"
        } else {
            model.updateCatalog { c in if let i = c.songs.firstIndex(where: { $0.id == s.id }) { c.songs[i].title = t } }
        }
        renaming = nil
    }

    private var songCounts: [String: Int] { model.songStats.count }

    private func entry(_ title: String, sub: String? = nil, count: Int?, active: Bool, big: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(DS.font(big ? 19 : 17, big ? .bold : .semibold)).lineLimit(1)
                    if let sub, !sub.isEmpty { Text(sub).font(DS.font(13)).opacity(0.7).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(DS.label).monospacedDigit().opacity(0.7) }
            }
            .foregroundStyle(active ? DS.accent : DS.text)
            .padding(.horizontal, 12)
            .padding(.vertical, big ? 7 : 5)
            .frame(minHeight: DS.control)
            .listRowHover()
            .background(active ? DS.accent.opacity(0.14) : Color.clear, in: DS.shape)
            .overlay(alignment: .leading) {
                if active { Capsule().fill(DS.accent).frame(width: 3).padding(.vertical, 6) }
            }
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
    }
}

// MARK: - Browser: alle Videos oder Song-Seite, rechts das gewählte Video

struct BrowserView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let open = !model.selected.isEmpty
        ZStack(alignment: .trailing) {
            // Die Kacheln ordnen sich genau einmal neu, sofort und ohne Zwischenschritte.
            // Würde die Breite mitanimiert, springen Kacheln und Filterleiste mehrfach hin und her.
            Group {
                if model.page == .all { LibraryView() } else { SongPage() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, open ? 401 : 0)
            .transaction { $0.animation = nil }
            if open {
                HStack(spacing: 0) {
                    Rectangle().fill(DS.line).frame(width: 1)
                    Inspector(records: model.selected)
                        .frame(width: 400)
                        .id(model.selection)
                }
                .background(DS.bg)
                .transition(.move(edge: .trailing))
            }
        }
        // Nur die rechte Spalte gleitet rein und raus
        .animation(.smooth(duration: 0.3, extraBounce: 0), value: open)
        .onExitCommand { model.selection = [] }
    }
}

/// Seite eines Songs: oben Eingrenzen nach Format und Mood, darunter je eine Reihe
/// RAW, CUT, EDIT, FINAL. „Alle zeigen“ klappt eine Reihe zum Raster auf.
struct SongPage: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<String> = []
    /// Audio-Modul: eingeklappt, Notenknopf neben dem Namen klappt es auf
    @State private var audioOpen = Screenshots.requested != nil

    var body: some View {
        let all: [VideoRecord] = {
            switch model.page {
            case .song(let id): return model.records.filter { $0.songs.contains { $0.id == id } }
            case .noSong: return model.records.filter(\.noSong)
            case .all: return model.records
            }
        }()
        let list = model.pageRecords
        let c = model.catalog
        let song: SongItem? = { if case .song(let id) = model.page { return c.song(id) }; return nil }()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(song?.title ?? "ohne Song").font(DS.font(44, .bold)).lineLimit(1)
                    if let song { audioButton(song) }
                    Text("\(all.count) Videos").dsLabel()
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dim)
                        TextField("In diesem Song suchen …", text: $model.filter.text).textFieldStyle(.plain).font(DS.controlFont)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 280, height: DS.control)
                    .background(DS.surface, in: DS.shape)
                }
                // Ohne Audio bleibt der Hinweis „Audio fehlt“ immer sichtbar
                if let song, audioOpen || !song.hasAudio {
                    SongHeader(song: song)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                KindFilter(kinds: c.visibleKinds, selected: $model.filter.kindIDs,
                           counts: Dictionary(grouping: all, by: \.kind.id).mapValues(\.count))
                narrowing(all: all, catalog: c)
                if all.isEmpty {
                    Text("Noch keine Videos").font(DS.font(18)).foregroundStyle(DS.dim)
                }
                ForEach(c.visibleKinds.filter { model.filter.kindIDs.isEmpty || model.filter.kindIDs.contains($0.id) }) { k in
                    row(k, list.filter { $0.kind.id == k.id })
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func audioButton(_ song: SongItem) -> some View {
        let on = audioOpen && song.hasAudio
        return Button {
            withAnimation(.smooth(duration: 0.28)) { audioOpen.toggle() }
        } label: {
            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(on ? DS.bg : (song.hasAudio ? DS.accent : DS.amber))
                .frame(width: 44, height: 44)
                .background(on ? DS.accent : DS.surface, in: Circle())
                .overlay(Circle().stroke(song.hasAudio ? DS.accent.opacity(on ? 0 : 0.7) : DS.amber.opacity(0.7), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(DSPress())
        .disabled(!song.hasAudio)
        .help(song.hasAudio ? (on ? "Audio einklappen" : "Audio anhören") : "Audio fehlt")
        // Mitte des Knopfs auf Höhe der Titelmitte
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 14 }
    }

    /// Format- und Mood-Knöpfe, nur mit Werten, die in diesem Song vorkommen.
    @ViewBuilder
    private func narrowing(all: [VideoRecord], catalog c: Catalog) -> some View {
        let formatIDs = Set(all.map(\.format.id))
        let moodIDs = Set(all.flatMap { $0.moods.map(\.id) })
        let formats = c.formats.filter { formatIDs.contains($0.id) }.sorted { $0.order < $1.order }
        let moods = c.moods.filter { moodIDs.contains($0.id) }.sorted { $0.order < $1.order }
        if !formats.isEmpty || !moods.isEmpty {
            // Eine Zeile, seitlich scrollbar: Höhe bleibt gleich, wenn die Vorschau aufklappt
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.gap) {
                if !formats.isEmpty {
                    Text("Format").dsLabel().frame(height: DS.control)
                    ForEach(formats) { f in
                        Chip(title: f.name, state: model.filter.formatIDs.contains(f.id) ? .on : .off) { toggle(&model.filter.formatIDs, f.id) }
                    }
                }
                if !moods.isEmpty {
                    Text("Mood").dsLabel().frame(height: DS.control).padding(.leading, 10)
                    ForEach(moods) { m in
                        Chip(title: m.name, state: model.filter.moodIDs.contains(m.id) ? .on : .off) { toggle(&model.filter.moodIDs, m.id) }
                    }
                }
                if !model.filter.formatIDs.isEmpty || !model.filter.moodIDs.isEmpty || !model.filter.text.isEmpty || !model.filter.kindIDs.isEmpty {
                    Chip(title: "zurücksetzen", icon: "xmark") {
                        model.filter.formatIDs = []; model.filter.moodIDs = []; model.filter.text = ""; model.filter.kindIDs = []
                    }
                    .foregroundStyle(DS.dim)
                }
            }
            }
            .scrollClipDisabled()
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    @ViewBuilder
    private func row(_ k: ListItem, _ list: [VideoRecord]) -> some View {
        let open = expanded.contains(k.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(k.name).font(DS.font(26, .bold)).foregroundStyle(k.id == Kind.final ? DS.accent : DS.text)
                Text("\(list.count) Videos").dsLabel()
                if list.count > 1 {
                    Button { if open { expanded.remove(k.id) } else { expanded.insert(k.id) } } label: {
                        Text(open ? "Als Reihe ‹" : "Alle zeigen ›").dsLabel(DS.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if list.isEmpty {
                Text("Noch keine").font(DS.font(16)).foregroundStyle(DS.line).frame(height: 30)
            } else if open {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: DS.margin)], spacing: DS.margin) {
                    ForEach(list) { r in tile(r, in: list) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: DS.margin) {
                        ForEach(list) { r in tile(r, in: list).frame(width: 160) }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func tile(_ r: VideoRecord, in list: [VideoRecord]) -> some View {
        VideoTile(record: r, selected: model.selection.contains(r.id), showSong: false)
            // Ein Klick wählt sofort (ohne auf einen Doppelklick zu warten), der zweite öffnet
            .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { model.openVideo(r) } else { model.select(r, in: list) } }
            .contextMenu {
                Button("Öffnen") { model.openVideo(r) }
                Button("Im Finder zeigen") { model.showInFinder(r) }
            }
    }
}

// MARK: - Kachel mit Vorschau beim Drüberfahren

struct VideoTile: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var thumbs: ThumbStore
    var record: VideoRecord
    var selected: Bool
    var showSong = true
    /// Kleine Kachel (Kompagnon): kleinere Schrift, ohne Datum
    var compact = false
    @State private var hover: CGFloat?

    var body: some View {
        let _ = thumbs.generation
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    DS.surface
                    image(size: g.size)
                    HStack(spacing: 4) {
                        Badge(record.kind.name, tint: record.kind.id == Kind.final ? DS.accent : nil, small: compact)
                        Spacer(minLength: 2)
                        if let d = record.media?.duration { Badge(d.clock, small: compact) }
                    }
                    .padding(compact ? 4 : 6)
                }
                .clipShape(DS.shape)
                .overlay(DS.shape.stroke(selected ? DS.accent : DS.line, lineWidth: selected ? 3 : 1))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = model.layoutMoving ? nil : min(max(p.x / max(g.size.width, 1), 0), 0.999)
                    case .ended: hover = nil
                    }
                }
            }
            .aspectRatio(4 / 5, contentMode: .fit)
            .onChange(of: model.layoutMoving) { _, moving in if moving { hover = nil } }
            if compact {
                Text(record.songTitle).font(DS.font(14, .bold)).lineLimit(1)
                Text("\(record.format.name) · \(record.moods.map(\.name).joined(separator: ", "))").font(DS.font(12)).foregroundStyle(DS.dim).lineLimit(1)
            } else if showSong {
                Text(record.songTitle).font(DS.font(17, .bold)).lineLimit(1)
                Text("\(record.format.name) · \(record.moods.map(\.name).joined(separator: ", "))").font(DS.font(14)).foregroundStyle(DS.dim).lineLimit(1)
            } else {
                Text(record.format.name).font(DS.font(17, .bold)).lineLimit(1)
                Text(record.moods.map(\.name).joined(separator: ", ")).font(DS.font(14)).foregroundStyle(DS.dim).lineLimit(1)
            }
            if !compact { Text(record.createdAt.day).dsLabel() }
        }
        .contentShape(Rectangle())
        .onDrag {
            if let u = model.url(record), FileManager.default.fileExists(atPath: u.path) {
                return NSItemProvider(contentsOf: u) ?? NSItemProvider()
            }
            return NSItemProvider()
        }
    }

    @ViewBuilder
    private func image(size: CGSize) -> some View {
        if let hover, let strip = thumbs.image(Previews.stripPath(record.id)) {
            let n = CGFloat(Previews.stripFrames)
            let aspect = strip.size.width / n / max(strip.size.height, 1)
            let fw = max(size.width, size.height * aspect)
            let fh = fw / max(aspect, 0.01)
            let idx = floor(hover * n)
            Image(nsImage: strip)
                .resizable()
                .frame(width: fw * n, height: fh)
                .offset(x: -idx * fw - (fw - size.width) / 2, y: -(fh - size.height) / 2)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
        } else if let poster = thumbs.image(Previews.posterPath(record.id)) {
            Image(nsImage: poster).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
        } else {
            Image(systemName: "film").font(.system(size: 30)).foregroundStyle(DS.line)
                .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - Bibliothek

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let list = model.visible
        Group {
            VStack(spacing: 0) {
                FilterBar(count: list.count)
                Rectangle().fill(DS.line).frame(height: 1)
                if list.isEmpty {
                    VStack(spacing: 12) {
                        Text(model.records.isEmpty ? "Noch nichts im Archiv" : "Nichts gefunden").font(DS.big)
                        if !model.filter.isEmpty {
                            DSButton("Filter zurücksetzen", icon: "xmark") { model.filter = LibraryFilter() }.frame(width: 240)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: DS.margin)], spacing: DS.margin) {
                            ForEach(list) { r in
                                VideoTile(record: r, selected: model.selection.contains(r.id))
                                    // Ein Klick wählt sofort (ohne auf einen Doppelklick zu warten), der zweite öffnet
                                    .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { model.openVideo(r) } else { model.select(r, in: list) } }
                                    .contextMenu { menu(r) }
                            }
                        }
                        .padding(DS.margin)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ r: VideoRecord) -> some View {
        Button("Öffnen") { model.openVideo(r) }
        Button("Im Finder zeigen") { model.showInFinder(r) }
        Divider()
        Button("Song-Seite „\(r.songTitle)“") { model.showSong(of: r) }
        Button("Alle im Format „\(r.format.name)“") {
            model.filter = LibraryFilter()
            model.filter.formatIDs = [r.format.id]
        }
    }
}

// MARK: - Filter

struct FilterBar: View {
    @EnvironmentObject var model: AppModel
    var count: Int

    var body: some View {
        let c = model.catalog
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: DS.gap) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DS.dim)
                    TextField("Freitext: Song, Beschreibung, Tags, Notizen …", text: $model.filter.text)
                        .textFieldStyle(.plain).font(DS.controlFont)
                    if !model.filter.text.isEmpty {
                        Button { model.filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.dim) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 240)
                .frame(height: DS.control)
                .background(DS.surface, in: DS.shape)
                .layoutPriority(1)
                Text("\(count) Videos").dsLabel().fixedSize().frame(minWidth: 70, alignment: .trailing)
                if !model.filter.isEmpty {
                    DSButton("Zurücksetzen", icon: "xmark") { model.filter = LibraryFilter() }.frame(width: 150)
                }
            }
            // Song, Art-Knöpfe, Format, Mood, Weitere: immer eine Zeile (bei schmalem Fenster seitlich scrollen),
            // damit die Höhe beim Auf- und Zuklappen der Vorschau gleich bleibt
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.gap) {
                FilterMenu(title: "Song", summary: songSummary(c), active: !model.filter.songIDs.isEmpty || model.filter.noSong, flow: false) {
                    SongFilterList()
                }
                KindFilter(kinds: c.visibleKinds, selected: $model.filter.kindIDs)
                FilterMenu(title: "Format", summary: names(model.filter.formatIDs, c.formats), active: !model.filter.formatIDs.isEmpty) {
                    ForEach(c.formats.sorted { $0.order < $1.order }) { f in
                        Chip(title: f.name, state: model.filter.formatIDs.contains(f.id) ? .on : .off) { toggle(&model.filter.formatIDs, f.id) }
                    }
                }
                FilterMenu(title: "Mood", summary: names(model.filter.moodIDs, c.moods, joiner: " + "), active: !model.filter.moodIDs.isEmpty) {
                    ForEach(c.moods.sorted { $0.order < $1.order }) { m in
                        Chip(title: m.name, state: model.filter.moodIDs.contains(m.id) ? .on : .off) { toggle(&model.filter.moodIDs, m.id) }
                    }
                }
                FilterMenu(title: "Weitere", summary: moreSummary, active: !model.filter.tags.isEmpty || model.filter.from != nil || model.filter.to != nil) {
                    MoreFilters()
                }
            }
            }
            .scrollClipDisabled()
        }
        .padding(DS.margin)
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func names(_ ids: Set<String>, _ list: [ListItem], joiner: String = ", ") -> String {
        ids.isEmpty ? "alle" : list.filter { ids.contains($0.id) }.map(\.name).joined(separator: joiner)
    }

    private func songSummary(_ c: Catalog) -> String {
        var parts = c.songs.filter { model.filter.songIDs.contains($0.id) }.map(\.title)
        if model.filter.noSong { parts.append("ohne Song") }
        return parts.isEmpty ? "alle" : parts.joined(separator: ", ")
    }

    private var moreSummary: String {
        var parts: [String] = []
        if !model.filter.tags.isEmpty { parts.append(model.filter.tags.sorted().joined(separator: ", ")) }
        if model.filter.from != nil || model.filter.to != nil {
            parts.append("\(model.filter.from?.day ?? "…") bis \(model.filter.to?.day ?? "heute")")
        }
        if model.sort != .createdDesc { parts.append(model.sort.title) }
        return parts.isEmpty ? "Sortierung, Tags, Zeitraum" : parts.joined(separator: " · ")
    }
}

/// Filterknopf mit Auswahl im Popover.
/// Song-Filter: Suchfeld und Liste, zuletzt benutzte Songs zuerst, beim Tippen unscharf eingegrenzt.
/// Mehrere Songs gleichzeitig möglich, Klick schaltet an und aus.
struct SongFilterList: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @FocusState private var focus: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let songs = Self.matches(q, in: model.songsByActivity)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.dim)
                TextField("Song suchen …", text: $query).textFieldStyle(.plain).font(DS.controlFont).focused($focus)
                if !model.filter.songIDs.isEmpty || model.filter.noSong {
                    Button("alle") { model.filter.songIDs = []; model.filter.noSong = false }
                        .buttonStyle(.plain).font(DS.label).foregroundStyle(DS.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: DS.control)
            .background(DS.surface, in: DS.shape)
            .overlay(DS.shape.stroke(DS.line, lineWidth: 1))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(songs) { s in
                        row(s.display, on: model.filter.songIDs.contains(s.id)) {
                            if model.filter.songIDs.contains(s.id) { model.filter.songIDs.remove(s.id) } else { model.filter.songIDs.insert(s.id) }
                        }
                    }
                    if model.records.contains(where: \.noSong), q.isEmpty || "ohne song".contains(q.lowercased()) {
                        row("ohne Song", on: model.filter.noSong) { model.filter.noSong.toggle() }.opacity(0.8)
                    }
                    if songs.isEmpty { Text("Kein Song gefunden").dsLabel().padding(10) }
                }
            }
            .frame(maxHeight: 320)
        }
        .onAppear { focus = true }
    }

    /// Treffer nach Güte, bei gleicher Güte in der Reihenfolge „zuletzt benutzt“
    static func matches(_ q: String, in all: [SongItem]) -> [SongItem] {
        guard !q.isEmpty else { return all }
        var scored: [(song: SongItem, score: Int, index: Int)] = []
        for (i, s) in all.enumerated() {
            let sc = SongSearch.score(q, s.display)
            if sc > 0 { scored.append((s, sc, i)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map(\.song)
    }

    private func row(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(DS.controlFont).lineLimit(1)
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
            }
            .foregroundStyle(on ? DS.bg : DS.text)
            .padding(.horizontal, 10)
            .frame(height: DS.control)
            .listRowHover()
            .background(on ? DS.accent : Color.clear, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(.plain)
    }
}

struct FilterMenu<Content: View>: View {
    var title: String
    var summary: String
    var active: Bool
    /// false: Inhalt bringt sein eigenes Layout mit (z. B. Liste mit Suche)
    var flow = true
    @ViewBuilder var content: () -> Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).dsLabel(active ? DS.bg : DS.dim).fixedSize()
                Text(summary).font(DS.controlFont).lineLimit(1).frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(active ? DS.bg : DS.text)
            .padding(.horizontal, 12)
            .frame(height: DS.control)
            .background(active ? DS.accent : DS.surface, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Group {
                if flow {
                    ScrollView { FlowLayout { content() }.padding(DS.margin) }
                } else {
                    ScrollView { content().padding(DS.margin) }
                }
            }
            .frame(width: 460)
            .frame(maxHeight: flow ? 420 : 680)
            .background(DS.bg)
            .foregroundStyle(DS.text)
        }
    }
}

struct MoreFilters: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sortierung").dsLabel()
            FlowLayout {
                ForEach(SortOrder.allCases) { o in
                    Chip(title: o.title, state: model.sort == o ? .on : .off) { model.sort = o }
                }
            }
            Text("Zeitraum (Entstehung)").dsLabel()
            FlowLayout {
                preset("7 Tage", days: 7)
                preset("30 Tage", days: 30)
                preset("12 Monate", days: 365)
                Chip(title: "alle", state: model.filter.from == nil && model.filter.to == nil ? .on : .off) {
                    model.filter.from = nil; model.filter.to = nil
                }
            }
            RangeCalendar(from: $model.filter.from, to: $model.filter.to,
                          marked: Set(model.records.map { Calendar.current.startOfDay(for: $0.createdAt) }))
            Text("Tags").dsLabel()
            FlowLayout {
                ForEach(model.catalog.tags, id: \.self) { t in
                    Chip(title: t, state: model.filter.tags.contains(t) ? .on : .off) {
                        if model.filter.tags.contains(t) { model.filter.tags.remove(t) } else { model.filter.tags.insert(t) }
                    }
                }
                if model.catalog.tags.isEmpty { Text("Noch keine Tags").font(DS.font(15)).foregroundStyle(DS.dim) }
            }
        }
        .frame(width: 428, alignment: .leading)
    }

    private func preset(_ title: String, days: Int) -> some View {
        let from = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let on = model.filter.to == nil && model.filter.from.map { Calendar.current.isDate($0, inSameDayAs: from) } == true
        return Chip(title: title, state: on ? .on : .off) {
            model.filter.from = on ? nil : from
            model.filter.to = nil
        }
    }
}

// MARK: - Rechts: Video ansehen und Angaben ändern

struct Inspector: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var thumbs: ThumbStore
    var records: [VideoRecord]
    @State private var draft: [Attrs] = []
    @State private var player: AVPlayer?
    @State private var ready = false
    @StateObject private var playback = PlaybackState()
    @State private var pendingSave: Task<Void, Never>?

    private var original: [Attrs] { records.map(Attrs.init) }
    private var changed: Bool { !draft.isEmpty && draft != original }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if records.count == 1, let r = records.first {
                        preview(r)
                        info(r)
                    } else {
                        Text("\(records.count) Videos ausgewählt").font(DS.font(28, .bold))
                    }
                    if !draft.isEmpty {
                        AttributeEditor(attrs: $draft)
                    }
                }
                .padding(DS.margin)
            }
            // Änderungen speichern sich selbst; Hinweis nur, wenn das gerade nicht geht
            if changed, let why = blocked {
                Rectangle().fill(DS.line).frame(height: 1)
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.font(15, .semibold)).foregroundStyle(DS.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.margin)
            }
        }
        .background(DS.surface.opacity(0.35))
        .onAppear { draft = original }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear {
            player?.pause()
            playback.detach()
            if pendingSave != nil { pendingSave?.cancel(); if changed, blocked == nil { save() } }
        }
    }

    private var blocked: String? {
        if !model.online { return "SSD fehlt, Änderung wird nicht gespeichert" }
        if !draft.allSatisfy(\.complete) { return "Pflichtangabe fehlt, gespeichert wird, sobald alles gesetzt ist" }
        return nil
    }

    /// Kurz nach der letzten Änderung speichern (beim Tippen nicht bei jedem Buchstaben)
    private func scheduleSave() {
        pendingSave?.cancel()
        guard changed, blocked == nil else { pendingSave = nil; return }
        pendingSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            pendingSave = nil
            if changed, blocked == nil { save() }
        }
    }

    private func save() {
        var out: [VideoRecord] = []
        for (r, a) in zip(records, draft) {
            var rec = r
            a.apply(to: &rec, catalog: model.catalog)
            out.append(rec)
        }
        model.save(out)
    }

    @ViewBuilder
    private func preview(_ r: VideoRecord) -> some View {
        let url = model.url(r)
        if model.online, let url, FileManager.default.fileExists(atPath: url.path) {
            let poster = thumbs.image(Previews.posterPath(r.id))
            VStack(spacing: 8) {
                PlayerView(player: player)
                    .aspectRatio(Self.aspect(r, poster: poster), contentMode: .fit)
                    .frame(maxHeight: 420)
                    // Bis das erste Bild des Videos da ist, steht das Standbild im selben Format davor
                    .overlay {
                        if !ready, let poster {
                            Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .clipShape(DS.shape)
                    // Klick ins Bild: Abspielen / Pause
                    .overlay(Color.clear.contentShape(Rectangle()).onTapGesture { playback.toggle() })
                    .frame(maxWidth: .infinity)
                PlayerBar(state: playback, fallback: r.media?.duration ?? 0)
            }
            // Player erst nach dem Aufklappen laden, damit die Animation nicht hakt
            .task(id: url) {
                // Altes Video sofort weg, sonst steht es kurz im Format des neuen
                if player != nil {
                    player?.pause()
                    playback.detach()
                    player = nil
                }
                ready = false
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                let p = AVPlayer(url: url)
                player = p
                playback.attach(p)
                // Standbild erst wegnehmen, wenn das Video wirklich ein Bild zeigen kann
                for _ in 0..<60 where !Task.isCancelled {
                    if p.currentItem?.status != .unknown { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if !Task.isCancelled { ready = true }
            }
        } else {
            VideoTile(record: r, selected: false).frame(width: 220)
        }
    }

    /// Seitenverhältnis der Vorschau: vom Standbild (immer richtig gedreht), sonst aus den Videodaten
    static func aspect(_ r: VideoRecord, poster: NSImage?) -> CGFloat {
        if let s = poster?.size, s.width > 0, s.height > 0 { return s.width / s.height }
        if let w = r.media?.width, let h = r.media?.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16 / 9
    }

    private func info(_ r: VideoRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.file).font(DS.font(15, .semibold)).lineLimit(2).textSelection(.enabled)
            Group {
                line("Entstanden", r.createdAt.dayTime + (r.createdAtSource == "file" ? " (Datei)" : ""))
                line("Hinzugefügt", r.importedAt.dayTime)
                line("Größe", r.size.bytes + (r.media?.duration.map { " · \($0.clock)" } ?? ""))
                if let w = r.media?.width, let h = r.media?.height {
                    line("Bild", "\(w)×\(h)" + (r.media?.fps.map { String(format: " · %.0f fps", $0) } ?? "") + (r.media?.codec.map { " · \($0)" } ?? ""))
                }
                line("Original", r.originalName)
            }
            HStack(spacing: DS.gap) {
                DragOutButton(url: model.url(r))
                DSButton("Im Finder", icon: "folder") { model.showInFinder(r) }
            }
            .padding(.top, 6)
        }
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).dsLabel().frame(width: 96, alignment: .leading)
            Text(v).font(DS.font(15)).lineLimit(2).textSelection(.enabled)
        }
    }
}

/// Wiedergabe mit den normalen macOS-Bedienelementen.
struct PlayerView: NSViewRepresentable {
    var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        // Eigene schlanke Steuerung darunter (PlayerBar), nichts über dem Bild
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Abspielstand des Vorschau-Players für die eigene Steuerung.
@MainActor
final class PlaybackState: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    private weak var player: AVPlayer?
    private var token: Any?

    func attach(_ p: AVPlayer) {
        detach()
        player = p
        token = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                let d = p.currentItem?.duration.seconds ?? 0
                if d.isFinite, d > 0 { self.duration = d }
                self.playing = p.rate != 0
            }
        }
    }

    func detach() {
        if let token, let player { player.removeTimeObserver(token) }
        token = nil
        playing = false
    }

    func toggle() {
        guard let p = player else { return }
        if p.rate != 0 {
            p.pause()
        } else {
            if duration > 0, time >= duration - 0.1 { p.seek(to: .zero) }
            NowPlaying.claim(self) { [weak self] in
                guard let self, let p = self.player else { return }
                p.pause()
                p.seek(to: .zero)
                self.time = 0
                self.playing = false
            }
            p.play()
        }
        playing = p.rate != 0
    }

    func seek(_ t: Double) {
        time = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// Schlanke Steuerung unter der Vorschau: Play/Pause, Zeitleiste zum Springen, Zeit.
struct PlayerBar: View {
    @ObservedObject var state: PlaybackState
    var fallback: Double

    var body: some View {
        let total = state.duration > 0 ? state.duration : fallback
        HStack(spacing: 10) {
            Button { state.toggle() } label: {
                Image(systemName: state.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.bg)
                    .frame(width: 32, height: 32)
                    .background(DS.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(DSPress())
            .help(state.playing ? "Pause" : "Abspielen")
            Slider(value: Binding(get: { min(state.time, max(total, 0.1)) }, set: { state.seek($0) }), in: 0...max(total, 0.1))
                .tint(DS.accent)
                .controlSize(.small)
            Text("\(state.time.clock) / \(total > 0 ? total.clock : "–")")
                .font(DS.font(14, .semibold)).monospacedDigit().foregroundStyle(DS.dim)
                .fixedSize()
        }
    }
}

/// Knopf zum Rausziehen: gedrückt halten und ziehen, dann hat man die echte Videodatei in der Hand
/// (wie aus dem Finder), z. B. für den Schnitt, den Finder oder den Browser.
struct DragOutButton: View {
    var url: URL?
    @State private var hover = false

    private var available: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw").font(.system(size: 14, weight: .semibold))
            Text("Ziehen").font(DS.body).tracking(0.8).textCase(.uppercase)
        }
        .lineLimit(1).minimumScaleFactor(0.5)
        .foregroundStyle(available ? DS.text : DS.dim)
        .frame(maxWidth: .infinity)
        .frame(height: DS.control)
        .background(hover && available ? DS.surfaceHi : DS.surface, in: DS.shape)
        .overlay(DS.shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(hover && available ? DS.accent : DS.line))
        .contentShape(DS.shape)
        .onHover { h in
            hover = h
            if h, available { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onDrag {
            guard let url, available else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .help(available ? "Gedrückt halten und in eine andere App oder den Finder ziehen" : "Video nicht erreichbar (SSD angeschlossen?)")
    }
}
