import AppKit
import SwiftUI

/// Kompagnon: kleines Fenster, das über allen Apps schwebt und frei verschoben werden kann.
/// Schneller Zugriff aufs Archiv und Videos direkt in eine andere App ziehen. Bleibt offen,
/// auch wenn das große Fenster zu ist. Hat seine eigene Suche, unabhängig vom großen Fenster.
struct CompanionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var filter = LibraryFilter()
    @State private var songID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: DS.gap) {
                search
                kinds
                songs
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Rectangle().fill(DS.line).frame(height: 1)
            content
        }
        .background(DS.bg)
        .foregroundStyle(DS.text)
        .onAppear { model.companionOpen = true }
        .onDisappear { model.companionOpen = false }
    }

    private var list: [VideoRecord] {
        var f = filter
        if let songID { f.songIDs = [songID] }
        return SortOrder.importedDesc.sort(f.apply(model.records))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("KOMPAGNON").font(DS.font(15, .bold)).tracking(1.5)
            Spacer()
            Button { openWindow(id: "main") } label: {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 28).background(DS.surface, in: DS.shape).contentShape(DS.shape)
            }
            .buttonStyle(DSPress())
            .help("Großes Archiv-Fenster öffnen")
        }
        .padding(.leading, 76) // Platz für die Fensterknöpfe
        .padding(.trailing, 12)
        .frame(height: 40)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.dim)
            TextField("Suchen …", text: $filter.text).textFieldStyle(.plain).font(DS.controlFont)
            if !filter.text.isEmpty {
                Button { filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.dim) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: DS.control)
        .background(DS.surface, in: DS.shape)
    }

    /// RAW, CUT, EDIT, FINAL gleich breit über die ganze Zeile; zweiter Klick nimmt wieder raus
    private var kinds: some View {
        HStack(spacing: 6) {
            ForEach(model.catalog.visibleKinds) { k in
                let on = filter.kindIDs.contains(k.id)
                Button {
                    if on { filter.kindIDs.remove(k.id) } else { filter.kindIDs.insert(k.id) }
                } label: {
                    Text(k.name).font(DS.font(15, .bold)).tracking(0.8)
                        .frame(maxWidth: .infinity).frame(height: DS.control)
                        .foregroundStyle(on ? DS.bg : DS.text)
                        .background(on ? DS.accent : DS.surface, in: DS.shape)
                        .contentShape(DS.shape)
                }
                .buttonStyle(DSPress())
            }
        }
    }

    /// Zuletzt benutzte Songs zum Antippen
    private var songs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.songsByActivity.prefix(12)) { s in
                    Chip(title: s.title, state: songID == s.id ? .on : .off) {
                        songID = songID == s.id ? nil : s.id
                    }
                }
            }
        }
        .frame(height: DS.control)
    }

    @ViewBuilder
    private var content: some View {
        let items = list
        if !model.online {
            Text("SSD „\(model.rememberedVolume)“ fehlt").font(DS.font(16, .bold)).foregroundStyle(DS.amber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text(model.records.isEmpty ? "Noch nichts im Archiv" : "Nichts gefunden").font(DS.font(18, .bold)).foregroundStyle(DS.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 10)], spacing: 12) {
                    ForEach(items) { r in
                        VideoTile(record: r, selected: false)
                            .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { model.openVideo(r) } }
                            .contextMenu {
                                Button("Öffnen") { model.openVideo(r) }
                                Button("Im Finder zeigen") { model.showInFinder(r) }
                            }
                    }
                }
                .padding(12)
            }
        }
    }
}

/// Knopf oben im Archiv: öffnet den Kompagnon, zweiter Klick schließt ihn. Orange, solange er offen ist.
struct CompanionButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let on = model.companionOpen
        Button {
            if on { dismissWindow(id: "kompagnon") } else { openWindow(id: "kompagnon") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "pip").font(.system(size: 15, weight: .semibold))
                Text("Kompagnon").font(DS.controlFont)
            }
            .padding(.horizontal, 12)
            .frame(height: DS.control)
            .foregroundStyle(on ? DS.bg : DS.text)
            .background(on ? DS.accent : DS.surface, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .fixedSize()
        .help("Kleines Fenster, das über allen Apps bleibt (⌘K)")
    }
}

/// Menüpunkt „Kompagnon“ (⌘K)
struct CompanionMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Kompagnon") { openWindow(id: "kompagnon") }.keyboardShortcut("k")
    }
}

/// Hält das Kompagnon-Fenster über allen Apps und auf jedem Schreibtisch (über AppKit, läuft ab macOS 14).
struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.apply(v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(v.window) }
    }

    private static func apply(_ w: NSWindow?) {
        guard let w, w.level != .floating else { return }
        w.level = .floating
        w.collectionBehavior.insert(.canJoinAllSpaces)
        w.collectionBehavior.insert(.fullScreenAuxiliary)
    }
}
