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
    @State private var mainShown = true
    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 8) {
                // Vorschläge der Suche liegen über den Art-Knöpfen
                search.zIndex(1)
                kinds
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .zIndex(1)
            Rectangle().fill(DS.line).frame(height: 1)
            content
        }
        // Kopfzeile teilt sich die Zeile mit den Fensterknöpfen, spart Platz
        .ignoresSafeArea(edges: .top)
        .background(DS.bg)
        .foregroundStyle(DS.text)
        .onAppear { model.companionOpen = true; refreshMain() }
        .onDisappear { model.companionOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshMain() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            DispatchQueue.main.async { refreshMain() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in refreshMain() }
    }

    private var list: [VideoRecord] {
        var f = filter
        if let songID { f.songIDs = [songID] }
        return SortOrder.importedDesc.sort(f.apply(model.records))
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            Text("KOMPAGNON").font(DS.font(13, .bold)).tracking(1.4).foregroundStyle(DS.dim)
                .allowsHitTesting(false)
            Spacer()
            // Großes Fenster ein- und ausblenden; orange, solange es zu sehen ist
            Button { toggleMain() } label: {
                Image(systemName: "macwindow").font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 22)
                    .foregroundStyle(mainShown ? DS.bg : DS.text)
                    .background(mainShown ? DS.accent : DS.surface, in: DS.shape)
                    .contentShape(DS.shape)
            }
            .buttonStyle(DSPress())
            .help(mainShown ? "Großes Fenster ausblenden" : "Großes Fenster einblenden")
        }
        .padding(.leading, 86) // Platz für die Fensterknöpfe, mit etwas Luft
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(WindowDragArea())
    }

    private func refreshMain() {
        let w = WindowFinder.main
        mainShown = w.map { $0.isVisible && !$0.isMiniaturized } ?? false
    }

    private func toggleMain() {
        if let w = WindowFinder.main, w.isVisible, !w.isMiniaturized {
            w.orderOut(nil)
            mainShown = false
        } else {
            openWindow(id: "main")
            WindowFinder.main?.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
            mainShown = true
        }
    }

    // MARK: Suche: Freitext und Songs in einem Feld

    private var suggestions: [SongItem] {
        let q = filter.text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, songID == nil else { return [] }
        return model.catalog.visibleSongs
            .map { ($0, SongSearch.score(q, $0.title)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(5).map(\.0)
    }

    private var search: some View {
        let sugg = suggestions
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.dim)
            if let id = songID, let s = model.catalog.song(id) {
                // Gewählter Song als Marke im Feld, Klick nimmt ihn wieder raus
                Button { songID = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "music.note").font(.system(size: 10, weight: .bold))
                        Text(s.title).font(DS.font(14, .bold)).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .foregroundStyle(DS.bg)
                    .background(DS.accent, in: DS.shape)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            TextField(songID == nil ? "Song oder Stichwort …" : "Stichwort …", text: $filter.text)
                .textFieldStyle(.plain).font(DS.font(15, .semibold))
                .focused($searching)
                .onSubmit { if let first = sugg.first { pick(first) } }
            if !filter.text.isEmpty {
                Button { filter.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.dim) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(DS.surface, in: DS.shape)
        // Vorschläge schweben über der Liste, nichts verschiebt sich
        .overlay(alignment: .top) {
            if searching, !sugg.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sugg) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "music.note").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.accent)
                                Text(s.title).font(DS.font(15, .bold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(model.songStats.count[s.id] ?? 0)").font(DS.label).foregroundStyle(DS.dim)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DSPress())
                    }
                }
                .padding(.vertical, 4)
                .background(DS.surfaceHi, in: DS.shape)
                .overlay(DS.shape.stroke(DS.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .offset(y: 36)
            }
        }
    }

    private func pick(_ s: SongItem) {
        songID = s.id
        filter.text = ""
    }

    /// RAW, CUT, EDIT, FINAL klein und gleich breit; zweiter Klick nimmt wieder raus
    private var kinds: some View {
        HStack(spacing: 4) {
            ForEach(model.catalog.visibleKinds) { k in
                let on = filter.kindIDs.contains(k.id)
                Button {
                    if on { filter.kindIDs.remove(k.id) } else { filter.kindIDs.insert(k.id) }
                } label: {
                    Text(k.name).font(DS.font(12, .bold)).tracking(0.8)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(on ? DS.bg : DS.text)
                        .background(on ? DS.accent : DS.surface, in: DS.shape)
                        .contentShape(DS.shape)
                }
                .buttonStyle(DSPress())
            }
        }
    }

    // MARK: Videos

    @ViewBuilder
    private var content: some View {
        let items = list
        if !model.online {
            Text("SSD „\(model.rememberedVolume)“ fehlt").font(DS.font(15, .bold)).foregroundStyle(DS.amber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text(model.records.isEmpty ? "Noch nichts im Archiv" : "Nichts gefunden").font(DS.font(16, .bold)).foregroundStyle(DS.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 170), spacing: 10)], spacing: 14) {
                    ForEach(items) { r in
                        VideoTile(record: r, selected: false, compact: true)
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

/// Die beiden Fenster der App finden (für Ein-/Ausblenden und Zurückholen)
@MainActor
enum WindowFinder {
    static func window(_ id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }
    static var main: NSWindow? { window("main") }
    static var companion: NSWindow? { window("kompagnon") }

    /// Kompagnon oben rechts ins große Fenster holen (falls er irgendwo verloren gegangen ist)
    static func recallCompanion() {
        guard let c = companion else { return }
        let target = main.flatMap { $0.isVisible ? $0.frame : nil } ?? NSScreen.main?.visibleFrame ?? c.frame
        let origin = NSPoint(x: target.maxX - c.frame.width - 24, y: target.maxY - c.frame.height - 72)
        c.setFrameOrigin(origin)
        c.orderFrontRegardless()
    }
}

/// Knopf oben im Archiv: öffnet den Kompagnon, zweiter Klick schließt ihn. Orange, solange er offen ist.
/// Lange drücken holt ihn zurück ins große Fenster.
struct CompanionButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var longPressed = false

    var body: some View {
        let on = model.companionOpen
        Button {
            // Nach langem Drücken nicht zusätzlich schließen
            if longPressed { longPressed = false; return }
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
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            longPressed = true
            if !on { openWindow(id: "kompagnon") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (on ? 0 : 0.3)) { WindowFinder.recallCompanion() }
        })
        .fixedSize()
        .help("Kleines Fenster, das über allen Apps bleibt (⌘K). Lange drücken holt es hierher zurück.")
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
