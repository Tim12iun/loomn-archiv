import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Kleines Fenster nach dem Reinziehen: Angaben für den ganzen Stapel. Links die Videos
/// (Auswahl = für wen die Angaben gelten, so lassen sich gemischte Stapel aufteilen),
/// rechts die Angaben. Enter = ins Archiv, sobald alle Pflichtangaben gesetzt sind.
/// Ist kein Video angehakt, legt der Import nur einen Song an (Name, Audiodatei dazu nach Wunsch).
struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var songTitle = ""
    @State private var songFile: URL?
    @State private var working = false
    @State private var songError: String?
    @State private var dropTarget = false

    private var draft: ImportDraft { model.importDraft ?? ImportDraft(urls: [], catalog: model.catalog) }

    private var editable: [ImportDraft.Item] { draft.selectedItems }
    /// Kein Video angehakt: nur einen Song anlegen
    private var songOnly: Bool { draft.importable.isEmpty }
    private var songName: String { songTitle.trimmingCharacters(in: .whitespaces) }
    private var ready: Bool { songOnly ? !songName.isEmpty && !working : draft.ready }

    private var attrsBinding: Binding<[Attrs]> {
        Binding(
            get: { editable.map(\.attrs) },
            set: { new in
                let items = editable
                for (item, a) in zip(items, new) { model.importDraft?.update(item.id) { $0.attrs = a } }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ins Archiv").font(DS.font(34, .bold))
                if !songOnly {
                    Text("\(draft.importable.count) Videos · \(draft.importable.reduce(Int64(0)) { $0 + $1.size }.bytes)").dsLabel()
                }
                Spacer()
                if let root = model.libraryRoot {
                    if FileOps.isInternal(root) {
                        Label("Archiv liegt auf dem Mac, nicht auf der SSD", systemImage: "exclamationmark.triangle.fill")
                            .font(DS.font(15, .semibold)).foregroundStyle(DS.amber)
                    } else {
                        Text("nach \(FileOps.volumeName(root) ?? root.lastPathComponent)").dsLabel()
                    }
                }
            }
            .padding(DS.margin)
            Rectangle().fill(DS.line).frame(height: 1)
            HStack(spacing: 0) {
                fileList.frame(width: 330).frame(maxHeight: .infinity, alignment: .top)
                Rectangle().fill(DS.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if draft.items.count > 1 { hint }
                        if editable.isEmpty {
                            songForm
                        } else {
                            AttributeEditor(attrs: attrsBinding, compact: true)
                        }
                    }
                    .padding(DS.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(DS.line).frame(height: 1)
            HStack(spacing: DS.gap) {
                if working { ProgressView().controlSize(.small) }
                Text(footer).font(DS.font(16)).foregroundStyle(ready ? DS.dim : DS.accent).lineLimit(2)
                Spacer()
                DSButton("Abbrechen") { model.cancelImport() }
                    .frame(width: 150)
                    .keyboardShortcut(.cancelAction)
                DSButton("Ins Archiv ⏎", icon: "tray.and.arrow.down.fill", fill: ready ? DS.accent : nil, height: DS.primary) {
                    if songOnly { createSong() } else { model.commitImport(keyboard: NSApp.currentEvent?.type == .keyDown) }
                }
                .frame(width: 240)
                .disabled(!ready)
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.margin)
        }
        .frame(width: 1020, height: 760)
        .background(DS.bg)
        .overlay { if dropTarget { DS.shape.stroke(DS.accent, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        // Draufziehen: Videos kommen in den Stapel, eine Audiodatei wird zum Song
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            RootView.loadURLs(providers) { add($0) }
            return true
        }
        .foregroundStyle(DS.text)
        .preferredColorScheme(.dark)
    }

    /// Oben rechts: für wen die Angaben gelten, wo sie abweichen, und „Auf alle übernehmen“.
    @ViewBuilder
    private var hint: some View {
        let diff = Attrs.differing(editable.map(\.attrs))
        if editable.count == 1, let one = editable.first, draft.importable.count > 1 {
            HStack(spacing: DS.gap) {
                Spacer(minLength: 4)
                DSButton("Auf alle übernehmen", icon: "square.on.square") { copyToAll(one) }
                    .frame(width: 250)
                    .help("Diese Angaben für alle Videos im Stapel setzen")
            }
        } else if !diff.isEmpty {
            Label("Weicht ab: \(diff.joined(separator: ", "))",
                  systemImage: "exclamationmark.triangle.fill")
                .font(DS.font(16, .semibold)).foregroundStyle(DS.amber)
        }
    }

    private func copyToAll(_ item: ImportDraft.Item) {
        guard var d = model.importDraft else { return }
        for i in d.items.indices { d.items[i].attrs = item.attrs }
        d.selection = Set(d.items.map(\.id))
        model.importDraft = d
    }

    private var footer: String {
        if songOnly {
            if let songError { return songError }
            return songName.isEmpty ? "Noch offen: Song" : ""
        }
        if draft.ready {
            let diff = Attrs.differing(draft.importable.map(\.attrs))
            return diff.isEmpty ? "" : "Weicht ab: \(diff.joined(separator: ", "))"
        }
        let missing = Set(draft.importable.flatMap(\.attrs.missing))
        let order = ["Art", "Song", "Format"].filter { missing.contains($0) }
        return "Noch offen: \(order.joined(separator: ", "))" + (draft.incomplete < draft.importable.count ? " (bei \(draft.incomplete) Videos)" : "")
    }

    // MARK: Liste links

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Videos").dsLabel()
                if !Attrs.differing(draft.importable.map(\.attrs)).isEmpty {
                    Text("unterschiedlich").dsLabel(DS.amber).help("Die Videos haben nicht alle dieselben Angaben")
                }
                Spacer()
                Button("+ Videos") { if let urls = Self.chooseVideos() { add(urls) } }.buttonStyle(.plain).font(DS.label).foregroundStyle(DS.accent)
                Button("Alle") { model.importDraft?.selection = Set(draft.items.map(\.id)) }.buttonStyle(.plain).font(DS.label)
                Button("Keine") { model.importDraft?.selection = [] }.buttonStyle(.plain).font(DS.label)
            }
            .foregroundStyle(DS.dim)
            .padding(.horizontal, DS.margin)
            .padding(.vertical, 10)
            if draft.items.isEmpty {
                Button { if let urls = Self.chooseVideos() { add(urls) } } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 26)).foregroundStyle(DS.accent)
                        Text("Videos hierher ziehen").font(DS.font(18, .bold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.surface.opacity(0.5), in: DS.shape)
                    .overlay(DS.shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])).foregroundStyle(DS.accent.opacity(0.6)))
                    .contentShape(DS.shape)
                }
                .buttonStyle(DSPress())
                .padding(DS.gap)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(draft.items) { item in row(item) }
                    }
                    .padding(.horizontal, DS.gap)
                }
            }
        }
    }

    private func row(_ item: ImportDraft.Item) -> some View {
        let sel = draft.selection.contains(item.id)
        return HStack(spacing: 10) {
            Image(systemName: sel ? "checkmark.square.fill" : "square")
                .font(.system(size: 15)).foregroundStyle(sel ? DS.accent : DS.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).font(DS.font(16, .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.size.bytes).dsLabel()
                    status(item)
                }
            }
            Spacer(minLength: 0)
            Button { model.importDraft?.remove([item.id]) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.dim)
            }
            .buttonStyle(.plain)
            .help("Aus dem Stapel nehmen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(sel ? DS.surfaceHi : Color.clear, in: DS.shape)
        .contentShape(Rectangle())
        .onTapGesture { tap(item) }
    }

    @ViewBuilder
    private func status(_ item: ImportDraft.Item) -> some View {
        if !item.attrs.complete {
            Text("fehlt: \(item.attrs.missing.joined(separator: ", "))").dsLabel(DS.accent)
        } else {
            Text("\(model.catalog.kind(item.attrs.kindID)?.name ?? "") · bereit").dsLabel()
        }
        // Nur ein Hinweis, das Video kommt trotzdem ins Archiv
        if item.duplicateOf != nil {
            Text("· schon im Archiv").dsLabel()
        } else if item.batchDuplicate {
            Text("· doppelt im Stapel").dsLabel()
        }
    }

    // MARK: Nur Song

    private var songForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Block(title: "Song", required: true, missing: songName.isEmpty) {
                DSField(placeholder: "Songname", text: $songTitle, onSubmit: createSong)
            }
            Block(title: "Audiodatei") {
                if let songFile {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.accent)
                        Text(songFile.lastPathComponent).font(DS.controlFont).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(FileOps.size(songFile).bytes).dsLabel()
                        Button { self.songFile = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dim)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: DS.control)
                    .background(DS.surface, in: DS.shape)
                } else {
                    AudioDropZone { setAudio($0) }
                }
            }
        }
    }

    private func setAudio(_ u: URL) {
        songFile = u
        if songName.isEmpty { songTitle = u.deletingPathExtension().lastPathComponent }
    }

    private func createSong() {
        guard songOnly, ready else { return }
        let title = songName
        let existing = model.catalog.songs.first { $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard let file = songFile else {
            if let s = model.newSong(title) { model.cancelImport(); model.page = .song(s.id) }
            return
        }
        working = true
        songError = nil
        Task {
            do {
                let s = try await model.addSongAudio(to: existing?.id, title: title, from: file)
                model.cancelImport()
                model.page = .song(s.id)
            } catch {
                songError = error.localizedDescription
                working = false
            }
        }
    }

    // MARK: Dateien dazu

    private func add(_ urls: [URL]) {
        if let audio = urls.first(where: SongAudio.isAudio), urls.allSatisfy(SongAudio.isAudio) {
            setAudio(audio)
            model.importDraft?.selection = []
            return
        }
        let videos = urls.filter { !SongAudio.isAudio($0) }
        if !videos.isEmpty { model.beginImport(videos) }
    }

    static func chooseVideos() -> [URL]? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Hinzufügen"
        p.allowedContentTypes = [.movie, .video, .folder]
        return p.runModal() == .OK ? p.urls : nil
    }

    private func tap(_ item: ImportDraft.Item) {
        guard var d = model.importDraft else { return }
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if d.selection.contains(item.id) { d.selection.remove(item.id) } else { d.selection.insert(item.id) }
        } else if mods.contains(.shift), let anchor = d.items.firstIndex(where: { d.selection.contains($0.id) }),
                  let i = d.items.firstIndex(where: { $0.id == item.id }) {
            d.selection = Set(d.items[min(anchor, i)...max(anchor, i)].map(\.id))
        } else {
            // Klick schaltet nur dieses Video an oder aus (wie ein Häkchen)
            if d.selection.contains(item.id) { d.selection.remove(item.id) } else { d.selection.insert(item.id) }
        }
        model.importDraft = d
    }
}
