import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Einstellungen: Mediathek (Ort, Umzug, Wartung), Listen (Formate, Moods), Tags, Updates.
/// Songs werden in der Hauptansicht verwaltet (Rechtsklick in der Song-Liste).
/// Alle Listen liegen in der Mediathek auf der SSD und ziehen mit um.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: ToolUpdater
    var startTab: Int?
    private var tab: Int { model.settingsTab }

    init(tab: Int? = nil) { startTab = tab }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.gap) {
                item("Mediathek", 0)
                item("Formate", 1)
                item("Moods", 2)
                item("Tags", 4)
                item("Updates", 5)
                Spacer()
            }
            .frame(width: 220)
            .padding(DS.margin)
            Rectangle().fill(DS.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case 0: LibrarySettings()
                    case 1: ListEditor(title: "Content-Formate", kind: .formats)
                    case 2: ListEditor(title: "Moods", kind: .moods)
                    case 4: TagList()
                    default: UpdateSettings()
                    }
                }
                .padding(DS.margin * 2)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .onAppear { if let startTab { model.settingsTab = startTab } }
    }

    private func item(_ title: String, _ i: Int) -> some View {
        DSButton(title, active: tab == i) { model.settingsTab = i }
    }
}

// MARK: Mediathek

struct LibrarySettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text("Mediathek").font(DS.big)
        if let root = model.libraryRoot {
            VStack(alignment: .leading, spacing: 8) {
                row("Ort", root.path)
                row("Laufwerk", FileOps.volumeName(root) ?? "–")
                if let free = model.freeSpace {
                    row("Frei", "\(free.bytes)" + (model.totalSpace.map { " von \($0.bytes)" } ?? ""))
                }
                row("Videos", "\(model.records.count) · \(model.records.reduce(Int64(0)) { $0 + $1.size }.bytes)")
            }
            HStack(spacing: DS.gap) {
                DSButton("Im Finder zeigen", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                DSButton("Umziehen …", icon: "arrow.right.doc.on.clipboard") { relocate() }
            }
        } else {
            Text("SSD „\(model.rememberedVolume)“ ist nicht angeschlossen")
                .font(DS.font(18)).foregroundStyle(DS.amber)
            DSButton("Erneut suchen", icon: "arrow.clockwise") { model.reconnect() }.frame(width: 220)
        }

        Text("Wartung").dsLabel().padding(.top, 10)
        HStack(spacing: DS.gap) {
            DSButton("Index neu aufbauen", icon: "arrow.triangle.2.circlepath") { model.rebuildIndex() }.disabled(!model.online)
            DSButton("Vorschauen neu erzeugen", icon: "photo.on.rectangle") { model.regeneratePreviews() }.disabled(!model.online)
        }

        Text("Anderer Speicherort").dsLabel().padding(.top, 10)
        DSButton("Speicherort wählen …", icon: "externaldrive") { model.chooseStorage() }.frame(width: 300)
    }

    private func relocate() {
        guard let target = model.chooseFolder(prompt: "Hierhin umziehen", message: "Neuen Ort für die Mediathek wählen, z. B. eine andere SSD.") else { return }
        let a = NSAlert()
        a.messageText = "Mediathek kopieren?"
        a.informativeText = "Alle \(model.records.count) Videos werden nach „\(target.path)“ kopiert und geprüft. Das kann bei großen Mediatheken Stunden dauern."
        a.addButton(withTitle: "Kopieren")
        a.addButton(withTitle: "Abbrechen")
        if a.runModal() == .alertFirstButtonReturn { model.relocate(toParent: target) }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).dsLabel().frame(width: 110, alignment: .leading)
            Text(v).font(DS.font(17)).textSelection(.enabled).lineLimit(2)
        }
    }
}

// MARK: Formate und Moods

struct ListEditor: View {
    enum Kind { case formats, moods }
    @EnvironmentObject var model: AppModel
    var title: String
    var kind: Kind
    @State private var dragging: String?

    private var list: [ListItem] {
        (kind == .formats ? model.catalog.formats : model.catalog.moods).sorted { $0.order < $1.order }
    }

    private func usage(_ id: String) -> Int {
        kind == .formats ? model.records.filter { $0.format.id == id }.count
            : model.records.filter { $0.moods.contains { $0.id == id } }.count
    }

    var body: some View {
        Text(title).font(DS.big)
        VStack(spacing: 6) {
            ForEach(list) { item in
                HStack(spacing: DS.gap) {
                    // Griff: Zeile anfassen und hoch oder runter ziehen (die ganze Zeile wandert mit)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.dim)
                        .frame(width: 28, height: DS.control)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    RenameField(value: item.name) { new in change(item.id) { $0.name = new } }
                    Text("\(usage(item.id)) Videos").dsLabel().frame(width: 90, alignment: .trailing)
                    deleteButton {
                        confirmDelete(name: item.name, entry: kind == .formats ? .format(item.id) : .mood(item.id),
                                      what: kind == .formats ? "ein Format" : "einen Mood",
                                      options: list.filter { $0.id != item.id }.map { ($0.id, $0.name) }, model: model)
                    }
                }
                .padding(.horizontal, 4)
                .background(DS.bg, in: DS.shape)
                .background(dragging == item.id ? DS.accent.opacity(0.12) : Color.clear, in: DS.shape)
                .contentShape(DS.shape)
                // Ziehen an der ganzen Zeile: Die Vorschau am Mauszeiger ist die vollständige Zeile
                .onDrag {
                    dragging = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(of: [.text], delegate: ReorderDrop(target: item.id, dragging: $dragging) { from, to in move(from, to: to) })
            }
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
        AddInline(placeholder: kind == .formats ? "Neues Format" : "Neuer Mood") { name in
            if kind == .formats { model.newFormat(name) } else { model.newMood(name) }
        }
    }

    private func change(_ id: String, _ f: @escaping (inout ListItem) -> Void) {
        model.updateCatalog { c in
            if kind == .formats {
                if let i = c.formats.firstIndex(where: { $0.id == id }) { f(&c.formats[i]) }
            } else {
                if let i = c.moods.firstIndex(where: { $0.id == id }) { f(&c.moods[i]) }
            }
        }
    }

    /// Eintrag `from` an die Stelle von `to` schieben.
    private func move(_ from: String, to: String) {
        var ordered = list
        guard let i = ordered.firstIndex(where: { $0.id == from }), let j = ordered.firstIndex(where: { $0.id == to }), i != j else { return }
        let item = ordered.remove(at: i)
        ordered.insert(item, at: j)
        let orders = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        model.updateCatalog { c in
            if kind == .formats {
                for i in c.formats.indices { c.formats[i].order = orders[c.formats[i].id] ?? c.formats[i].order }
            } else {
                for i in c.moods.indices { c.moods[i].order = orders[c.moods[i].id] ?? c.moods[i].order }
            }
        }
    }
}

/// Papierkorb ohne Kasten.
func deleteButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "trash")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(DS.dim)
            .frame(width: 32, height: DS.control)
            .contentShape(Rectangle())
    }
    .buttonStyle(DSPress())
    .help("Löschen")
}

/// Löschen mit kurzer Rückfrage, wenn Videos betroffen sind. Pflichtangaben bleiben nie leer:
/// wo nötig, wird ein Ersatz gewählt.
@MainActor
func confirmDelete(name: String, entry: AppModel.Entry, what: String, options: [(String, String)], model: AppModel) {
    let used = model.usage(entry).count
    guard used > 0 else { model.delete(entry, replacement: nil); return }
    let need = model.needReplacement(entry).count
    let a = NSAlert()
    a.messageText = "„\(name)“ löschen?"
    var popup: NSPopUpButton?
    if need == 0 {
        a.informativeText = used == 1 ? "Wird bei 1 Video entfernt." : "Wird bei \(used) Videos entfernt."
    } else if options.isEmpty {
        a.messageText = "„\(name)“ kann noch nicht gelöscht werden"
        a.informativeText = "Jedes Video braucht \(what). Lege zuerst einen anderen Eintrag an, dann kannst du diesen löschen."
        a.runModal()
        return
    } else {
        a.informativeText = (need == 1 ? "1 Video hätte" : "\(need) Videos hätten") + " sonst keinen Eintrag mehr. Stattdessen bekommen sie:"
        let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28), pullsDown: false)
        p.addItems(withTitles: options.map(\.1))
        a.accessoryView = p
        popup = p
    }
    a.addButton(withTitle: "Löschen")
    a.addButton(withTitle: "Abbrechen")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let rep = popup.map { options[max($0.indexOfSelectedItem, 0)].0 }
    model.delete(entry, replacement: rep)
}

/// Zeilen per Ziehen umsortieren: beim Drüberziehen rückt der Eintrag sofort an die neue Stelle.
struct ReorderDrop: DropDelegate {
    var target: String
    @Binding var dragging: String?
    var move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { move(d, target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Feld, das erst bei Enter oder beim Verlassen speichert.
struct RenameField: View {
    var value: String
    var placeholder = "Name"
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focus: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(DS.font(18, .semibold))
            .padding(.horizontal, 12)
            .frame(height: DS.control)
            .background(DS.surface, in: DS.shape)
            .focused($focus)
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focus { text = v } }
            .onSubmit(save)
            .onChange(of: focus) { _, f in if !f { save() } }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { text = value; return }
        if t != value { commit(t) }
    }
}

// MARK: Tags

struct TagList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let counts = Dictionary(grouping: model.records.flatMap(\.tags), by: { $0.lowercased() }).mapValues(\.count)
        Text("Tags").font(DS.big)
        FlowLayout {
            ForEach(model.catalog.tags, id: \.self) { t in
                HStack(spacing: 0) {
                    Chip(title: "\(t) · \(counts[t.lowercased()] ?? 0)") {
                        model.page = .all; model.filter = LibraryFilter(); model.filter.tags = [t]; model.showSettings = false
                    }
                    deleteButton { confirmDelete(name: t, entry: .tag(t), what: "", options: [], model: model) }
                }
            }
        }
    }
}

// MARK: Updates

struct UpdateSettings: View {
    @EnvironmentObject var updater: ToolUpdater

    var body: some View {
        Text("Updates").font(DS.big)
        Text("Installiert: Version \(updater.currentVersion) · Build \(updater.currentBuild)").font(DS.font(20, .bold))
        DSButton("Jetzt nach Updates suchen", icon: "arrow.down.circle") { updater.check(manual: true) }.frame(width: 320)
            .disabled(updater.phase == .checking || updater.phase == .installing)
        UpdateBanner(inline: true)
            .onDisappear { if case .failed = updater.phase { updater.dismiss() } }
        if let last = updater.lastCheck {
            Text("Zuletzt geprüft: \(last.dayTime)").dsLabel()
        }
    }
}
