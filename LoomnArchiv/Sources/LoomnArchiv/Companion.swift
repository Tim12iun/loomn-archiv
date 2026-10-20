import AppKit
import SwiftUI

/// Kompagnon: kleines Fenster, das über allen Apps schwebt und frei verschoben werden kann.
/// Schneller Zugriff aufs Archiv und Videos direkt in eine andere App ziehen. Bleibt offen,
/// auch wenn das große Fenster zu ist. Hat seine eigene Suche, unabhängig vom großen Fenster.
struct CompanionView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: ToolUpdater
    @Environment(\.openWindow) private var openWindow
    @State private var filter = LibraryFilter()
    @State private var songID: String?
    @State private var mainShown = true
    @FocusState private var searching: Bool
    /// Markierter Vorschlag (Maus oder Pfeiltasten), Enter nimmt ihn
    @State private var marked = 0
    /// Eingeklappt: nur ein kleines Viereck, das man verschieben und per Klick wieder aufklappen kann
    /// Bewusst nicht gespeichert: nach Neustart oder erneutem Öffnen kommt immer der ganze Kompagnon
    @State private var collapsed = false

    /// Mindestgröße des aufgeklappten Kompagnons gilt nur aufgeklappt
    @State private var fullMin = true

    var body: some View {
        Group {
            if collapsed {
                CompanionBubble { setCollapsed(false) }
            } else {
                panel
            }
        }
        // Kleiner geht nicht: Suchfeld und RAW, CUT, EDIT, FINAL müssen ganz zu sehen sein
        .frame(minWidth: fullMin ? CompanionFold.minSize.width : nil, minHeight: fullMin ? CompanionFold.minSize.height : nil)
        .onAppear {
            model.companionOpen = true
            refreshMain()
            if Screenshots.requested == nil { updater.start() }
            AppDelegate.showMain = { showMain() }
            reopen()
        }
        // Wieder eingeblendet (Knopf oben rechts oder Menü): immer ausgeklappt
        .onReceive(NotificationCenter.default.publisher(for: CompanionFold.opened)) { _ in reopen() }
        .onDisappear { model.companionOpen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshMain() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            DispatchQueue.main.async { refreshMain() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in refreshMain() }
    }

    /// Aufgeklappt in normaler Größe, egal in welchem Zustand er zugemacht wurde
    private func reopen() {
        collapsed = false
        fullMin = true
        DispatchQueue.main.async { CompanionFold.restore(WindowFinder.companion) }
    }

    /// Ein- und Aufklappen: Das echte Fenster springt unsichtbar auf die neue Größe, sichtbar ist
    /// währenddessen nur eine Animation auf der Grafikkarte (Bild des Kompagnons und orange Fläche).
    /// So wird nichts bei jedem Schritt neu berechnet und es läuft flüssig.
    private func setCollapsed(_ on: Bool) {
        guard let w = WindowFinder.companion else { collapsed = on; fullMin = !on; return }
        if on {
            searching = false
            let target = CompanionFold.collapseTarget(w)
            let morph = CompanionMorph(from: w.frame, snapshot: CompanionMorph.snapshot(w), orange: 0)
            w.alphaValue = 0
            CompanionFold.chrome(w, collapsed: true)
            fullMin = false
            collapsed = true
            w.contentMinSize = NSSize(width: CompanionFold.size, height: 16)
            DispatchQueue.main.async { w.setFrame(target, display: true) }
            morph.run(to: target, orange: 1) {
                // Sicherheitshalber: das Fenster ist jetzt wirklich das Viereck
                if w.frame != target { w.setFrame(target, display: true) }
                w.alphaValue = 1
            }
        } else {
            let target = CompanionFold.expandTarget(w)
            let morph = CompanionMorph(from: w.frame, snapshot: nil, orange: 1)
            w.alphaValue = 0
            collapsed = false
            fullMin = true
            CompanionFold.chrome(w, collapsed: false)
            w.setFrame(target, display: true)
            // Sobald der Kompagnon in voller Größe gezeichnet ist, liegt sein Bild unter dem Orange
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                morph.setSnapshot(CompanionMorph.snapshot(w))
            }
            morph.run(to: target, orange: 0) { w.alphaValue = 1 }
        }
    }

    private var panel: some View {
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
        // Ist das große Fenster weg, zeigt der Kompagnon die Update-Karte
        .overlay(alignment: .bottom) { if !mainShown { UpdateBanner(compact: true) } }
    }

    private var list: [VideoRecord] {
        var f = filter
        if let songID { f.songIDs = [songID] }
        return SortOrder.importedDesc.sort(f.apply(model.records))
    }

    // MARK: Kopf

    private var header: some View {
        // Wird es schmal, fällt der Schriftzug weg statt umzubrechen
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("KOMPAGNON").font(DS.font(13, .bold)).tracking(1.4).foregroundStyle(DS.dim)
                    .lineLimit(1).fixedSize()
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                headerButtons
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                headerButtons
            }
        }
        .padding(.leading, 86) // Platz für die Fensterknöpfe, mit etwas Luft
        .padding(.trailing, 12)
        .frame(height: 38)
        // Doppelklick auf die freie Leiste klappt zum Viereck ein
        .background(WindowDragArea { setCollapsed(true) })
    }

    @ViewBuilder
    private var headerButtons: some View {
            // Zum kleinen Viereck einklappen
            Button { setCollapsed(true) } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .bold))
                    .frame(width: 30, height: 22)
                    .background(DS.surface, in: DS.shape)
                    .contentShape(DS.shape)
            }
            .buttonStyle(DSPress())
            .help("Einklappen")
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

    private func refreshMain() {
        let w = WindowFinder.main
        mainShown = w.map { $0.isVisible && !$0.isMiniaturized } ?? false
    }

    private func toggleMain() {
        if let w = WindowFinder.main, w.isVisible, !w.isMiniaturized {
            w.orderOut(nil)
            mainShown = false
        } else {
            showMain()
        }
    }

    private func showMain() {
        openWindow(id: "main")
        WindowFinder.main?.deminiaturize(nil)
        WindowFinder.main?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainShown = true
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
                .onDrag { model.songDragItem(s) }
            }
            TextField(songID == nil ? "Song oder Stichwort …" : "Stichwort …", text: $filter.text)
                .textFieldStyle(.plain).font(DS.font(15, .semibold))
                .focused($searching)
                .onSubmit { if !sugg.isEmpty { pick(sugg[min(marked, sugg.count - 1)]) } }
                .onKeyPress(.downArrow) { marked = min(marked + 1, max(sugg.count - 1, 0)); return sugg.isEmpty ? .ignored : .handled }
                .onKeyPress(.upArrow) { marked = max(marked - 1, 0); return sugg.isEmpty ? .ignored : .handled }
                .onChange(of: filter.text) { _, _ in marked = 0 }
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
                    ForEach(Array(sugg.enumerated()), id: \.element.id) { i, s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "music.note").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.accent)
                                Text(s.title).font(DS.font(15, .bold)).lineLimit(1)
                                Spacer(minLength: 4)
                                // Mit Audio: lässt sich rausziehen
                                if s.hasAudio {
                                    Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.dim)
                                }
                                Text("\(model.songStats.count[s.id] ?? 0)").font(DS.label).foregroundStyle(DS.dim)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .listRowHover(marked: i == marked)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DSPress())
                        .onHover { if $0 { marked = i } }
                        // Song direkt als Audiodatei in eine andere App ziehen
                        .onDrag { model.songDragItem(s) }
                    }
                }
                .padding(4)
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
                        .lineLimit(1).minimumScaleFactor(0.7)
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
        VStack(spacing: 0) {
            if model.online, let id = songID, let s = model.catalog.song(id), s.hasAudio {
                CompanionSongStrip(song: s).padding([.horizontal, .top], 12)
            }
            videos
        }
    }

    @ViewBuilder
    private var videos: some View {
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

/// Gewählter Song im Kompagnon: anhören, Version wählen und als Audiodatei in andere Apps ziehen
/// (ganze Zeile). Ohne Audio gibt es die Zeile nicht.
struct CompanionSongStrip: View {
    @EnvironmentObject var model: AppModel
    var song: SongItem
    @StateObject private var player = AudioPlayer()
    @State private var versionID: String?

    private var version: SongVersion? {
        song.versions.first { $0.id == versionID } ?? song.current
    }

    var body: some View {
        let v = version
        let url = v.flatMap { model.audioURL($0) }
        let on = url != nil && player.url == url && player.playing
        HStack(spacing: 10) {
            Button { if let url { player.toggle(url) } } label: {
                Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.bg)
                    .frame(width: 30, height: 30)
                    .background(url == nil ? DS.dim : DS.accent, in: Circle())
            }
            .buttonStyle(DSPress())
            .disabled(url == nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(DS.font(15, .bold)).lineLimit(1)
                Text(detail(v, url)).font(DS.font(12, .semibold)).foregroundStyle(DS.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if song.versions.count > 1 {
                Menu {
                    ForEach(song.versions.sorted { $0.number > $1.number }) { x in
                        Button("V\(x.number)" + (x.id == song.current?.id ? " (aktuell)" : "")) {
                            player.stop()
                            versionID = x.id
                        }
                    }
                } label: {
                    Text("V\(v?.number ?? 0)").font(DS.font(13, .bold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Version wählen")
            }
            Image(systemName: "hand.draw").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.dim)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(DS.surface, in: DS.shape)
        .contentShape(DS.shape)
        .onDrag { model.songDragItem(song, version: v) }
        .help(url == nil ? "Audio nicht erreichbar (SSD angeschlossen?)" : "Gedrückt halten und in eine andere App ziehen")
        .onChange(of: song.id) { _, _ in player.stop(); versionID = nil }
        .onDisappear { player.stop() }
    }

    private func detail(_ v: SongVersion?, _ url: URL?) -> String {
        guard let v else { return "" }
        guard url != nil else { return "Audio nicht erreichbar" }
        let ext = (url?.pathExtension ?? "").uppercased()
        return ["V\(v.number)", v.duration.map(\.clock), ext].compactMap { $0 }.joined(separator: " · ")
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
            if on { dismissWindow(id: "kompagnon") } else { CompanionFold.open(openWindow) }
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
            if !on { CompanionFold.open(openWindow) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (on ? 0 : 0.3)) { WindowFinder.recallCompanion() }
        })
        .fixedSize()
        .help("Kleines Fenster, das über allen Apps bleibt. Lange drücken holt es hierher zurück.")
    }
}

/// Eingeklappter Kompagnon: kleines Viereck. Doppelklick klappt auf, Ziehen verschiebt, einfacher Klick tut nichts.
struct CompanionBubble: View {
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        // Über das ganze Fenster, auch über den unsichtbaren Titelstreifen; das Symbol wird
        // an der echten Fenstermitte platziert, nicht am Inhaltsbereich
        // Auch der Inhalt im GeometryReader muss den Titelstreifen ignorieren, sonst rutscht
        // das Zeichen um dessen halbe Höhe nach unten
        GeometryReader { g in
            ZStack {
                DS.accent.brightness(hover ? 0.06 : 0)
                StackMark(unit: g.size.width * 0.0075)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                BubbleHandle(open: open)
            }
            .frame(width: g.size.width, height: g.size.height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Doppelklick zum Aufklappen, ziehen zum Verschieben")
    }
}

/// Zeichen von archivn: drei Balken, nach vorn größer (Design Language, Abschnitt 7), auf Orange in `bg`.
/// Gezeichnet statt Bild: bleibt scharf und sitzt exakt mittig (Raster 100 × 100, Inhalt 20…80 / 22…78).
struct StackMark: View {
    var unit: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            bar(x: 30, y: 22, w: 40, h: 11, r: 3, o: 0.4)
            bar(x: 25, y: 37, w: 50, h: 13, r: 3.5, o: 0.7)
            bar(x: 20, y: 54, w: 60, h: 24, r: 5, o: 1)
        }
        .frame(width: 100 * unit, height: 100 * unit, alignment: .topLeading)
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, o: Double) -> some View {
        RoundedRectangle(cornerRadius: r * unit, style: .continuous)
            .fill(DS.bg.opacity(o))
            .frame(width: w * unit, height: h * unit)
            .offset(x: x * unit, y: y * unit)
    }
}

/// Ziehen verschiebt, nur ein Doppelklick öffnet: Verschieben wird nie als Öffnen verstanden.
private struct BubbleHandle: NSViewRepresentable {
    var open: () -> Void
    func makeNSView(context: Context) -> HandleView { HandleView(open: open) }
    func updateNSView(_ v: HandleView, context: Context) { v.open = open }

    final class HandleView: NSView {
        var open: () -> Void
        init(open: @escaping () -> Void) { self.open = open; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { open() } else { window.performDrag(with: event) }
        }
    }
}

/// Fenster zwischen Kompagnon und Viereck umschalten. Die Größe des Kompagnons merkt sich die App.
@MainActor
enum CompanionFold {
    static let size: CGFloat = 64
    static let duration = 0.22
    /// Kleinste Größe des aufgeklappten Kompagnons
    static let minSize = CGSize(width: 178, height: 300)
    /// Standardgröße: drei Videos nebeneinander
    static let defaultSize = CGSize(width: 390, height: 640)
    /// Wird nach dem Öffnen des Kompagnon-Fensters gesendet
    static let opened = Notification.Name("kompagnon.geoeffnet")

    static var lastSize: NSSize {
        UserDefaults.standard.string(forKey: sizeKey).map(NSSizeFromString)
            .flatMap { $0.width >= minSize.width && $0.height >= minSize.height ? $0 : nil } ?? defaultSize
    }
    private static let sizeKey = "kompagnon.groesse"

    /// Kompagnon einblenden, immer ausgeklappt
    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: "kompagnon")
        DispatchQueue.main.async { NotificationCenter.default.post(name: opened, object: nil) }
    }

    /// Fensterknöpfe und Größe-Ändern nur im aufgeklappten Zustand
    static func chrome(_ w: NSWindow?, collapsed: Bool) {
        guard let w else { return }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = collapsed
        }
        if collapsed { w.styleMask.remove(.resizable) } else { w.styleMask.insert(.resizable) }
    }

    /// Normaler Kompagnon: Fensterknöpfe zeigen, und ein zu kleines Fenster (vom Viereck) auf die letzte Größe bringen
    static func restore(_ w: NSWindow?) {
        guard let w else { return }
        w.alphaValue = 1
        chrome(w, collapsed: false)
        guard w.frame.width < minSize.width || w.frame.height < minSize.height else { return }
        let s = lastSize
        let f = w.frame
        w.setFrame(fit(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)), display: true)
    }

    /// Schrumpft genau unter den Mauszeiger (mittig), am Bildschirmrand nach innen versetzt.
    /// Merkt sich die aktuelle Größe fürs nächste Aufklappen.
    static func collapseTarget(_ w: NSWindow) -> NSRect {
        UserDefaults.standard.set(NSStringFromSize(w.frame.size), forKey: sizeKey)
        let m = NSEvent.mouseLocation
        return fit(NSRect(x: m.x - size / 2, y: m.y - size / 2, width: size, height: size))
    }

    /// Klappt so auf, dass die Maus oben mittig in der Kopfleiste sitzt (das Fenster hängt unter ihr),
    /// in der zuletzt genutzten Größe, am Bildschirmrand nach innen versetzt
    static func expandTarget(_ w: NSWindow) -> NSRect {
        let s = lastSize
        let m = NSEvent.mouseLocation
        let header: CGFloat = 38
        return fit(NSRect(x: m.x - s.width / 2, y: m.y + header / 2 - s.height, width: s.width, height: s.height))
    }

    /// Immer ganz auf einem Bildschirm
    private static func fit(_ r: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(r) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return r }
        var out = r
        out.size.width = min(r.width, v.width)
        out.size.height = min(r.height, v.height)
        out.origin.x = min(max(r.minX, v.minX), v.maxX - out.width)
        out.origin.y = min(max(r.minY, v.minY), v.maxY - out.height)
        return out
    }
}

/// Animation des Ein- und Aufklappens in einem eigenen, durchsichtigen Fenster über allem:
/// zwei Ebenen (Bild des Kompagnons, darüber Orange mit Stapel), die gemeinsam ihre Größe ändern,
/// während das Orange ein- bzw. ausblendet. Läuft komplett auf der Grafikkarte.
@MainActor
final class CompanionMorph {
    private let overlay: NSWindow
    private let shot = CALayer()
    private let orange = CALayer()
    private let origin: CGPoint
    private static let radius: CGFloat = 10

    init(from frame: NSRect, snapshot: CGImage?, orange start: Float) {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let area = screen?.frame ?? frame
        origin = area.origin
        overlay = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        overlay.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: area.size))
        view.wantsLayer = true
        overlay.contentView = view
        let scale = screen?.backingScaleFactor ?? 2
        let local = Self.local(frame, origin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [shot, orange] {
            l.frame = local
            l.cornerRadius = Self.radius
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.contentsScale = scale
            view.layer?.addSublayer(l)
        }
        shot.contentsGravity = .topLeft
        shot.backgroundColor = NSColor(DS.bg).cgColor
        shot.contents = snapshot
        orange.backgroundColor = NSColor(DS.accent).cgColor
        orange.contentsGravity = .center
        orange.contents = Self.mark(scale: scale)
        orange.opacity = start
        CATransaction.commit()
        overlay.orderFrontRegardless()
        overlay.displayIfNeeded()
        CATransaction.flush()
    }

    func setSnapshot(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shot.contents = image
        CATransaction.commit()
    }

    func run(to frame: NSRect, orange end: Float, done: @escaping () -> Void) {
        let local = Self.local(frame, origin)
        CATransaction.begin()
        CATransaction.setAnimationDuration(CompanionFold.duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [overlay] in
            MainActor.assumeIsolated {
                done()
                // Erst wenn das echte Fenster wieder sichtbar ist, die Animation wegnehmen
                DispatchQueue.main.async { overlay.orderOut(nil) }
            }
        }
        shot.frame = local
        orange.frame = local
        orange.opacity = end
        CATransaction.commit()
    }

    private static func local(_ r: NSRect, _ origin: CGPoint) -> CGRect {
        CGRect(x: r.minX - origin.x, y: r.minY - origin.y, width: r.width, height: r.height)
    }

    /// Bild des ganzen Fensters samt Kopfleiste
    static func snapshot(_ w: NSWindow) -> CGImage? {
        guard let v = w.contentView?.superview ?? w.contentView else { return nil }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    /// Stapel-Zeichen in Viereck-Größe
    private static func mark(scale: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: StackMark(unit: CompanionFold.size * 0.0075))
        r.scale = scale
        return r.cgImage
    }
}

/// Menüpunkt „Kompagnon“ (bewusst ohne Tastenkürzel, damit nichts mit anderen Apps kollidiert)
struct CompanionMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Kompagnon") { CompanionFold.open(openWindow) }
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
