import AppKit
import SwiftUI

/// Angaben für ein oder mehrere Videos: Art, Song, Format, Mood (Pflicht), Beschreibung, Tags, Notiz.
/// Bei mehreren Videos mit unterschiedlichen Werten zeigt ein orangefarbener Rahmen „gemischt“;
/// ein Klick setzt den Wert für alle.
struct AttributeEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var attrs: [Attrs]
    /// Beim Import: höchstens 3 Tags, Notiz eingeklappt
    var compact = false

    private var catalog: Catalog { model.catalog }

    private func state(_ has: (Attrs) -> Bool) -> ChipState {
        let n = attrs.filter(has).count
        return n == 0 ? .off : (n == attrs.count ? .on : .mixed)
    }

    private func setAll(_ change: (inout Attrs) -> Void) {
        var a = attrs
        for i in a.indices { change(&a[i]) }
        attrs = a
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            kindBlock
            SongPicker(attrs: $attrs)
                .zIndex(1)   // aufgeklappte Liste liegt über den Feldern darunter
            formatBlock
            moodBlock
            tagBlock
            if !compact { notesBlock }
        }
    }

    // MARK: Art

    private var kindBlock: some View {
        Block(title: "Art", required: true, missing: attrs.contains { $0.kindID == nil }) {
            HStack(spacing: DS.gap) {
                ForEach(catalog.visibleKinds) { k in
                    let st = state { $0.kindID == k.id }
                    // Nochmal klicken wählt wieder ab
                    Button { setAll { $0.kindID = st == .on ? nil : k.id } } label: {
                        Text(k.name).font(DS.font(22, .bold)).tracking(1)
                        .foregroundStyle(st == .on ? DS.bg : DS.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: DS.primary)
                        .background(st == .on ? DS.accent : DS.surface, in: DS.shape)
                        .overlay(DS.shape.stroke(st == .mixed ? DS.accent : .clear, lineWidth: 2))
                        .contentShape(DS.shape)
                    }
                    .buttonStyle(DSPress())
                    .help(k.detail ?? k.name)
                }
            }
        }
    }

    // MARK: Format

    private var formatBlock: some View {
        Block(title: "Content-Format", required: true, missing: attrs.contains { $0.formatID == nil }) {
            FlowLayout {
                ForEach(catalog.visibleFormats) { f in
                    let st = state { $0.formatID == f.id }
                    Chip(title: f.name, state: st) { setAll { $0.formatID = st == .on ? nil : f.id } }
                }
                AddInline(title: "+ Format", placeholder: "Neues Format") { name in
                    if let f = model.newFormat(name) { setAll { $0.formatID = f.id } }
                }
            }
        }
    }

    // MARK: Mood

    private var moodBlock: some View {
        Block(title: "Mood", required: true, missing: attrs.contains { $0.moodIDs.isEmpty }) {
            FlowLayout {
                ForEach(catalog.visibleMoods) { m in
                    let st = state { $0.moodIDs.contains(m.id) }
                    Chip(title: m.name, state: st) { toggleMood(m.id, on: st != .on) }
                }
                AddInline(title: "+ Mood", placeholder: "Neuer Mood") { name in
                    if let m = model.newMood(name) { toggleMood(m.id, on: true) }
                }
            }
            MixedTextField(placeholder: "Kurze Beschreibung (optional)", values: attrs.map(\.description)) { t in
                setAll { $0.description = t }
            }
        }
    }

    private func toggleMood(_ id: String, on: Bool) {
        setAll { a in
            if on { if !a.moodIDs.contains(id) { a.moodIDs.append(id) } } else { a.moodIDs.removeAll { $0 == id } }
        }
    }

    // MARK: Tags

    private var tagBlock: some View {
        let used = Array(Set(attrs.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let recent = catalog.tags.filter { t in !used.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }.prefix(10)
        let limit = compact ? 3 : 20
        let full = attrs.contains { $0.tags.count >= limit }
        return Block(title: "Tags", trailing: compact ? "optional · bis 3" : "optional") {
            FlowLayout {
                ForEach(used, id: \.self) { t in
                    Chip(title: t, state: state { $0.tags.contains(t) }, icon: "xmark") {
                        setAll { $0.tags.removeAll { $0 == t } }
                    }
                }
                if !full {
                    ForEach(Array(recent), id: \.self) { t in
                        Chip(title: t) { addTag(t, limit: limit) }.opacity(0.75)
                    }
                    AddInline(title: "+ Tag", placeholder: "Neuer Tag") { addTag($0, limit: limit) }
                }
            }
        }
    }

    private func addTag(_ t: String, limit: Int) {
        let tag = t.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        setAll { a in
            if !a.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }), a.tags.count < limit { a.tags.append(tag) }
        }
    }

    // MARK: Notiz

    private var notesBlock: some View {
        Block(title: "Notiz", trailing: "optional") {
            MixedTextField(placeholder: "Notiz", values: attrs.map(\.notes)) { t in setAll { $0.notes = t } }
        }
    }
}

/// Textfeld für einen oder mehrere Werte. Unterschiedliche Werte: leer mit Hinweis „verschieden“.
struct MixedTextField: View {
    var placeholder: String
    var values: [String]
    var set: (String) -> Void
    @State private var text = ""
    @State private var loaded: [String]?

    private var common: String? { Set(values).count <= 1 ? (values.first ?? "") : nil }

    var body: some View {
        DSField(placeholder: common == nil ? "verschieden, Eingabe gilt für alle" : placeholder, text: $text)
            .onAppear(perform: sync)
            .onChange(of: values) { _, _ in if values != loaded { sync() } }
            .onChange(of: text) { _, t in
                if t != (common ?? "") || (common == nil && !t.isEmpty) {
                    set(t)
                    loaded = values.map { _ in t }
                }
            }
    }

    private func sync() {
        loaded = values
        text = common ?? ""
    }
}

/// Song wählen: genau ein Song pro Video. Klick ins Feld zeigt die zuletzt benutzten Songs,
/// Tippen filtert die Liste (Teilwörter, Groß-/Kleinschreibung und Akzente egal, auch Lücken wie „ncht“).
/// Ohne Treffer öffnet Enter „Neuer Song“ (Name plus Audiodatei).
struct SongPicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var attrs: [Attrs]
    @State private var text = ""
    @State private var open = false
    @State private var highlight = 0
    @State private var newSong: String?
    @FocusState private var focus: Bool

    private var catalog: Catalog { model.catalog }

    /// Gemeinsamer Song aller Videos; nil = keiner oder verschieden
    private var current: SongItem? {
        let firsts = Set(attrs.map { $0.songIDs?.first ?? "" })
        guard firsts.count == 1, let id = firsts.first, !id.isEmpty else { return nil }
        return catalog.song(id)
    }

    private var mixed: Bool { Set(attrs.map { $0.songIDs?.first ?? "" }).count > 1 }
    private var missing: Bool { attrs.contains { ($0.songIDs ?? []).isEmpty } }
    private var query: String { text.trimmingCharacters(in: .whitespaces) }

    /// Zuletzt benutzt zuerst: letzter Import mit dem Song, sonst Anlagedatum
    private var recency: [String: Date] {
        var d = model.songStats.lastUsed
        for s in catalog.songs where d[s.id] == nil { d[s.id] = s.created ?? .distantPast }
        for id in catalog.lastImport.songIDs ?? [] { d[id] = .distantFuture }
        return d
    }

    private var hits: [SongItem] {
        let rec = recency
        let byRecent = catalog.visibleSongs.sorted { (rec[$0.id] ?? .distantPast) > (rec[$1.id] ?? .distantPast) }
        if query.isEmpty { return Array(byRecent.prefix(30)) }
        let scored = byRecent.compactMap { s -> (SongItem, Int)? in
            let sc = SongSearch.score(query, s.display)
            return sc > 0 ? (s, sc) : nil
        }
        // stabil: bei gleicher Güte bleibt die Reihenfolge nach „zuletzt benutzt“
        return scored.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
    }

    private var canCreate: Bool {
        !query.isEmpty && !catalog.songs.contains { $0.title.caseInsensitiveCompare(query) == .orderedSame && !$0.hidden }
    }

    var body: some View {
        Block(title: "Song", required: true, missing: missing) {
            HStack(spacing: DS.gap) {
                field
                    // Liste schwebt über dem Rest, nichts darunter verschiebt sich
                    .overlay(alignment: .top) {
                        if open {
                            list.offset(y: DS.control + 6)
                                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                        }
                    }
                    .onClickOutside(extend: open ? listHeight + 6 : 0) { if open { close() } }
                // Neuer Song nur mit Audiodatei
                Chip(title: "+ Song") { create() }
                    .foregroundStyle(DS.dim)
                    .help("Neuen Song mit WAV oder MP3 anlegen")
            }
        }
        .sheet(item: Binding(get: { newSong.map(NewSongRequest.init) }, set: { newSong = $0?.title })) { r in
            NewSongSheet(initialTitle: r.title) { s in setSong(s.id) }
                .environmentObject(model)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.dim)
            ZStack(alignment: .leading) {
                // Gewählter Song steht im Feld, solange nicht gesucht wird
                if !open || text.isEmpty {
                    Text(current?.display ?? (mixed ? "verschieden, Auswahl gilt für alle" : "Song suchen oder neu eintippen"))
                        .font(current == nil ? DS.font(18) : DS.font(18, .semibold))
                        .foregroundStyle(current == nil || open ? DS.dim : DS.text)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.font(18, .semibold))
                    .focused($focus)
                    .onSubmit(submit)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand(perform: close)
            }
            if canCreate {
                ConfirmArrow(action: create)
            } else if current != nil, !open {
                Button { setSong(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dim)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Song entfernen")
            }
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dim)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: DS.control)
        .background(DS.surface, in: DS.shape)
        .overlay(DS.shape.stroke(open ? DS.accent : (missing ? DS.accent.opacity(0.5) : DS.line), lineWidth: 1))
        .contentShape(DS.shape)
        .onTapGesture { if !open { openList() } }
        .onChange(of: focus) { _, f in if f, !open { openList() } }
        // Solange die Liste offen ist, gehört Enter dem Songfeld
        .onChange(of: open) { _, o in model.pendingInput["song"] = o }
        .onChange(of: text) { _, t in
            highlight = 0
            if !t.isEmpty, !open { open = true }
        }
    }

    private var listHeight: CGFloat {
        let rows = max(hits.count + (canCreate ? 1 : 0), 1)
        return CGFloat(min(rows, 6)) * (DS.control + 2) + 10
    }

    private var list: some View {
        let items = hits
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                        row(s.display, index: i, icon: s.id == current?.id ? "checkmark" : nil) { pick(s) }
                            .id(i)
                    }
                    if canCreate {
                        row("„\(query)“ neu anlegen", index: items.count, icon: "plus", accent: true) { create() }
                            .id(items.count)
                    }
                    if items.isEmpty, !canCreate {
                        Text(catalog.visibleSongs.isEmpty ? "Noch keine Songs. Namen eintippen und Enter." : "Kein Song gefunden")
                            .dsLabel().padding(10)
                    }
                }
                .padding(4)
            }
            .frame(height: listHeight)
            .background(DS.surfaceHi, in: DS.shape)
            .overlay(DS.shape.stroke(DS.line, lineWidth: 1))
            .onChange(of: highlight) { _, h in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(h) } }
        }
    }

    private func row(_ title: String, index: Int, icon: String?, accent: Bool = false, action: @escaping () -> Void) -> some View {
        let active = index == highlight
        return Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(DS.controlFont).lineLimit(1)
                Spacer(minLength: 4)
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
            }
            .foregroundStyle(active ? DS.bg : (accent ? DS.accent : DS.text))
            .padding(.horizontal, 10)
            .frame(height: DS.control)
            .background(active ? DS.accent : .clear, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = index } }
    }

    private func openList() {
        open = true
        highlight = current.flatMap { c in hits.firstIndex { $0.id == c.id } } ?? 0
        focus = true
    }

    private func move(_ d: Int) {
        if !open { openList(); return }
        let n = hits.count + (canCreate ? 1 : 0)
        guard n > 0 else { return }
        highlight = min(max(highlight + d, 0), n - 1)
    }

    /// Enter: markierten Treffer nehmen, sonst Song neu anlegen
    private func submit() {
        let items = hits
        if highlight < items.count, !(query.isEmpty && !open) {
            pick(items[highlight]); return
        }
        create()
    }

    /// Neuer Song: kleines Fenster mit Name und Audiodatei (Name aus der Suche vorbelegt)
    private func create() {
        if let exact = catalog.songs.first(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame && !$0.hidden }), !query.isEmpty {
            pick(exact); return
        }
        let t = query
        close()
        newSong = t
    }

    private func pick(_ s: SongItem) {
        setSong(s.id)
        close()
    }

    private func setSong(_ id: String?) {
        var a = attrs
        for i in a.indices { a[i].songIDs = id.map { [$0] } }
        attrs = a
    }

    private func close() {
        open = false
        text = ""
        focus = false
        DispatchQueue.main.async { model.pendingInput["song"] = false }
    }
}

struct NewSongRequest: Identifiable {
    var title: String
    var id: String { "new-song" }
}

/// Unscharfe Suche für Songnamen. 0 = kein Treffer, höher = besser.
enum SongSearch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    static func score(_ query: String, _ name: String) -> Int {
        let q = fold(query).trimmingCharacters(in: .whitespaces)
        let n = fold(name)
        guard !q.isEmpty else { return 1 }
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 800 }
        let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let tokens = q.split(separator: " ").map(String.init)
        var total = 0
        for t in tokens {
            if words.contains(where: { $0.hasPrefix(t) }) { total += 300 }
            else if n.contains(t) { total += 150 }
            else if isSubsequence(t, of: n) { total += 40 }
            else { return 0 }
        }
        return total / max(tokens.count, 1)
    }

    private static func isSubsequence(_ t: String, of n: String) -> Bool {
        var it = n.makeIterator()
        for c in t {
            guard c != " " else { continue }
            var found = false
            while let x = it.next() { if x == c { found = true; break } }
            if !found { return false }
        }
        return true
    }
}
