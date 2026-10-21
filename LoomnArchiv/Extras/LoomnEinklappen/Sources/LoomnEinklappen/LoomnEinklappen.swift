import AppKit
import SwiftUI

// LoomnEinklappen: das Ein- und Aufklappen des archivn-Kompagnons zum Mitnehmen.
// Doppelklick auf die Kopfleiste: Das Fenster wird zum Viereck unter dem Mauszeiger.
// Doppelklick aufs Viereck: Es klappt in der zuletzt genutzten Größe wieder auf, mit der Maus oben mittig.
// Das Viereck lässt sich ziehen; ein einfacher Klick tut nichts.
// Die Animation läuft auf der Grafikkarte in einem eigenen, durchsichtigen Fenster über allem
// (Bild des Fensters plus Orange mit Zeichen). Das echte Fenster springt unsichtbar auf die neue Größe,
// deshalb wird nichts bei jedem Schritt neu berechnet und es läuft flüssig.
// Ab macOS 14, nur SwiftUI und AppKit, keine weiteren Abhängigkeiten.

/// Aussehen und Größen. Alles hat sinnvolle Vorgaben (wie im archivn-Kompagnon).
public struct LoomnFoldStyle {
    /// Farbe des Vierecks und der Animation (Orange heißt aktiv)
    public var accent: NSColor
    /// Hintergrund des Fensters (liegt in der Animation unter dem Bild)
    public var background: NSColor
    /// Kantenlänge des Vierecks
    public var bubbleSize: CGFloat
    /// Kleinste Größe aufgeklappt
    public var minSize: CGSize
    /// Größe beim ersten Aufklappen, danach gilt die zuletzt genutzte
    public var defaultSize: CGSize
    /// Dauer des Ein- und Aufklappens
    public var duration: Double
    /// Eckenradius während der Animation
    public var radius: CGFloat
    /// Höhe der Kopfleiste: Beim Aufklappen sitzt die Maus mittig darin
    public var headerHeight: CGFloat
    /// Fenster schwebt über allen Apps und auf jedem Schreibtisch
    public var floating: Bool
    /// Schlüssel, unter dem die aufgeklappte Größe gemerkt wird (pro Fenster eindeutig)
    public var sizeKey: String

    public init(accent: NSColor = NSColor(srgbRed: 1, green: 0.42, blue: 0.21, alpha: 1),
                background: NSColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1),
                bubbleSize: CGFloat = 64,
                minSize: CGSize = CGSize(width: 178, height: 300),
                defaultSize: CGSize = CGSize(width: 290, height: 445),
                duration: Double = 0.22,
                radius: CGFloat = 10,
                headerHeight: CGFloat = 38,
                floating: Bool = true,
                sizeKey: String = "loomn.einklappen.groesse") {
        self.accent = accent
        self.background = background
        self.bubbleSize = bubbleSize
        self.minSize = minSize
        self.defaultSize = defaultSize
        self.duration = duration
        self.radius = radius
        self.headerHeight = headerHeight
        self.floating = floating
        self.sizeKey = sizeKey
    }
}

/// Zustand und Logik des Einklappens für genau ein Fenster.
/// Anlegen (z. B. als `@StateObject`), den Inhalt in `LoomnFoldWindow` packen und die Kopfleiste mit
/// `.loomnFoldHeader(fold)` versehen. Mehr braucht es nicht.
@MainActor
public final class LoomnFold: ObservableObject {
    /// Eingeklappt: Das Fenster ist das Viereck
    @Published public private(set) var collapsed = false
    /// Fenster ist offen (für den Knopf im Hauptfenster: orange, solange offen)
    @Published public fileprivate(set) var isOpen = false
    /// Mindestgröße gilt nur aufgeklappt (sonst ließe sich das Fenster nicht zum Viereck machen)
    @Published fileprivate private(set) var fullMin = true

    public let style: LoomnFoldStyle
    public private(set) weak var window: NSWindow?
    fileprivate let mark: AnyView

    /// Darf gerade eingeklappt werden? (archivn: nicht, solange der Kompagnon angedockt ist)
    public var canCollapse: () -> Bool = { true }
    /// Viereck wird gezogen (Rahmen in Bildschirmkoordinaten), z. B. um Andockstellen zu prüfen
    public var onBubbleDragBegan: (() -> Void)?
    public var onBubbleMoved: ((NSRect) -> Void)?
    public var onBubbleDropped: ((NSRect) -> Void)?
    /// Nach dem Ein- bzw. Aufklappen (Animation fertig)
    public var onChange: ((Bool) -> Void)?

    /// `mark`: Zeichen auf dem Viereck, gezeichnet für die Fläche `bubbleSize` × `bubbleSize`
    public init<Mark: View>(style: LoomnFoldStyle = LoomnFoldStyle(), @ViewBuilder mark: () -> Mark) {
        self.style = style
        self.mark = AnyView(mark())
    }

    // MARK: Bedienen

    public func toggle() { collapsed ? expand() : collapse() }

    /// Zum Viereck unter dem Mauszeiger schrumpfen. Merkt sich die aktuelle Größe.
    public func collapse() {
        guard !collapsed, canCollapse() else { return }
        guard let w = window else { collapsed = true; fullMin = false; return }
        let target = collapseTarget(w)
        let morph = LoomnFoldMorph(fold: self, from: w.frame, snapshot: LoomnFoldMorph.snapshot(w), orange: 0)
        w.alphaValue = 0
        chrome(w, collapsed: true)
        fullMin = false
        collapsed = true
        w.contentMinSize = NSSize(width: style.bubbleSize, height: 16)
        DispatchQueue.main.async { w.setFrame(target, display: true) }
        morph.run(to: target, orange: 1) { [weak self] in
            // Sicherheitshalber: das Fenster ist jetzt wirklich das Viereck
            if w.frame != target { w.setFrame(target, display: true) }
            w.alphaValue = 1
            self?.onChange?(true)
        }
    }

    /// Aus dem Viereck in der zuletzt genutzten Größe aufklappen; die Maus sitzt oben mittig in der Kopfleiste.
    public func expand() {
        guard collapsed else { return }
        guard let w = window else { collapsed = false; fullMin = true; return }
        let target = expandTarget()
        let morph = LoomnFoldMorph(fold: self, from: w.frame, snapshot: nil, orange: 1)
        w.alphaValue = 0
        collapsed = false
        fullMin = true
        chrome(w, collapsed: false)
        w.setFrame(target, display: true)
        // Sobald das Fenster in voller Größe gezeichnet ist, liegt sein Bild unter dem Orange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            morph.setSnapshot(LoomnFoldMorph.snapshot(w))
        }
        morph.run(to: target, orange: 0) { [weak self] in
            w.alphaValue = 1
            self?.onChange?(false)
        }
    }

    /// Fenster (wieder) aufgeklappt zeigen, ohne Animation, z. B. nach dem Öffnen über ein Menü.
    /// Ein zu kleines Fenster (vom Viereck) kommt auf die zuletzt genutzte Größe.
    public func showExpanded() {
        collapsed = false
        fullMin = true
        guard let w = window else { return }
        w.alphaValue = 1
        chrome(w, collapsed: false)
        if w.frame.width < style.minSize.width || w.frame.height < style.minSize.height {
            let s = lastSize, f = w.frame
            w.setFrame(fit(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)), display: true)
        }
        w.orderFrontRegardless()
    }

    // MARK: Größe und Lage

    /// Zuletzt genutzte aufgeklappte Größe (zu kleine gemerkte Werte gelten nicht)
    public var lastSize: NSSize {
        UserDefaults.standard.string(forKey: style.sizeKey).map(NSSizeFromString)
            .flatMap { $0.width >= style.minSize.width && $0.height >= style.minSize.height ? $0 : nil } ?? style.defaultSize
    }

    private func collapseTarget(_ w: NSWindow) -> NSRect {
        UserDefaults.standard.set(NSStringFromSize(w.frame.size), forKey: style.sizeKey)
        let m = NSEvent.mouseLocation, s = style.bubbleSize
        return fit(NSRect(x: m.x - s / 2, y: m.y - s / 2, width: s, height: s))
    }

    private func expandTarget() -> NSRect {
        let s = lastSize, m = NSEvent.mouseLocation
        return fit(NSRect(x: m.x - s.width / 2, y: m.y + style.headerHeight / 2 - s.height, width: s.width, height: s.height))
    }

    /// Immer ganz auf einem Bildschirm, am Rand nach innen versetzt
    func fit(_ r: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(r) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return r }
        var out = r
        out.size.width = min(r.width, v.width)
        out.size.height = min(r.height, v.height)
        out.origin.x = min(max(r.minX, v.minX), v.maxX - out.width)
        out.origin.y = min(max(r.minY, v.minY), v.maxY - out.height)
        return out
    }

    /// Fensterknöpfe und Größe-Ändern nur im aufgeklappten Zustand
    private func chrome(_ w: NSWindow, collapsed: Bool) {
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = collapsed
        }
        if collapsed { w.styleMask.remove(.resizable) } else { w.styleMask.insert(.resizable) }
    }

    fileprivate func attach(_ w: NSWindow?) {
        guard let w, w !== window else { return }
        window = w
        if style.floating {
            w.level = .floating
            w.collectionBehavior.insert(.canJoinAllSpaces)
            w.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        chrome(w, collapsed: collapsed)
    }
}

// MARK: - Ansichten

/// Hülle für den Fensterinhalt: zeigt aufgeklappt `content`, eingeklappt das Viereck.
/// Die Szene dazu mit `.windowStyle(.hiddenTitleBar)` und `.windowResizability(.contentMinSize)` anlegen.
public struct LoomnFoldWindow<Content: View>: View {
    @ObservedObject private var fold: LoomnFold
    private let content: Content

    public init(_ fold: LoomnFold, @ViewBuilder content: () -> Content) {
        self.fold = fold
        self.content = content()
    }

    public var body: some View {
        Group {
            if fold.collapsed { LoomnFoldBubble(fold: fold) } else { content }
        }
        .frame(minWidth: fold.fullMin ? fold.style.minSize.width : nil,
               minHeight: fold.fullMin ? fold.style.minSize.height : nil)
        // Eingeklappt darf das Fenster zum Viereck werden. Die Höhe zählt hier ohne den unsichtbaren
        // Titelstreifen, deshalb kleiner, sonst wird das Viereck hochkant.
        .frame(minWidth: fold.style.bubbleSize, minHeight: 16)
        .background(LoomnWindowReader { fold.attach($0) })
        .onAppear { fold.isOpen = true; fold.showExpanded() }
        .onDisappear { fold.isOpen = false }
        // Erneut geöffnet (Knopf oder Menü), während das Fenster schon offen ist: immer aufgeklappt
        .onReceive(NotificationCenter.default.publisher(for: LoomnCompanion.opened)) { n in
            if n.object as? String == fold.style.sizeKey { fold.showExpanded() }
        }
    }
}

public extension View {
    /// Macht diese Fläche (die Kopfleiste) zum Griff: ziehen verschiebt das Fenster, Doppelklick klappt ein.
    /// Liegt hinter Knöpfen, die bleiben bedienbar.
    func loomnFoldHeader(_ fold: LoomnFold) -> some View {
        background(LoomnFoldHeaderArea { fold.collapse() })
    }
}

/// Das Viereck: Orange mit Zeichen, Doppelklick klappt auf, ziehen verschiebt.
struct LoomnFoldBubble: View {
    @ObservedObject var fold: LoomnFold
    @State private var hover = false

    var body: some View {
        // Über das ganze Fenster, auch über den unsichtbaren Titelstreifen; das Zeichen sitzt an der
        // echten Fenstermitte. Auch der Inhalt im GeometryReader muss den Titelstreifen ignorieren,
        // sonst rutscht das Zeichen um dessen halbe Höhe nach unten.
        GeometryReader { g in
            ZStack {
                Color(fold.style.accent).brightness(hover ? 0.06 : 0)
                fold.mark
                    .frame(width: fold.style.bubbleSize, height: fold.style.bubbleSize)
                    .scaleEffect(g.size.width / fold.style.bubbleSize)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                BubbleHandle(fold: fold)
            }
            .frame(width: g.size.width, height: g.size.height)
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Doppelklick zum Aufklappen, ziehen zum Verschieben")
    }
}

/// Ziehen verschiebt, nur ein Doppelklick öffnet: Verschieben wird nie als Öffnen verstanden.
private struct BubbleHandle: NSViewRepresentable {
    let fold: LoomnFold
    func makeNSView(context: Context) -> HandleView { HandleView(fold: fold) }
    func updateNSView(_ v: HandleView, context: Context) { v.fold = fold }

    final class HandleView: NSView {
        var fold: LoomnFold
        init(fold: LoomnFold) { self.fold = fold; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { fold.expand(); return }
            fold.onBubbleDragBegan?()
            moveManually(window) { [fold] in fold.onBubbleMoved?(window.frame) }
            fold.onBubbleDropped?(window.frame)
        }
    }
}

/// Kopfleiste: ziehen verschiebt (selbst, ohne das Kacheln von macOS am Bildschirmrand), Doppelklick klappt ein.
private struct LoomnFoldHeaderArea: NSViewRepresentable {
    var onDoubleClick: () -> Void
    func makeNSView(context: Context) -> DragView { DragView(onDoubleClick: onDoubleClick) }
    func updateNSView(_ v: DragView, context: Context) { v.onDoubleClick = onDoubleClick }

    final class DragView: NSView {
        var onDoubleClick: () -> Void
        init(onDoubleClick: @escaping () -> Void) { self.onDoubleClick = onDoubleClick; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { onDoubleClick() } else { moveManually(window) {} }
        }
    }
}

/// Fenster selbst mit der Maus mitführen, bis losgelassen wird
@MainActor
private func moveManually(_ window: NSWindow, moved: () -> Void) {
    let start = NSEvent.mouseLocation
    let origin = window.frame.origin
    while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
        let p = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        moved()
        if e.type == .leftMouseUp { break }
    }
}

/// Liefert das NSWindow, in dem die Ansicht liegt
private struct LoomnWindowReader: NSViewRepresentable {
    var found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { found(v.window) }
    }
}

// MARK: - Kompagnon zum Hauptfenster

/// Muster aus archivn: großes Hauptfenster (Bibliothek) und ein kleiner Kompagnon mit reduzierter
/// Oberfläche, der über allen Apps schwebt und sich per Doppelklick zum Viereck einklappen lässt.
/// Der Kompagnon ist eine eigene `Window`-Szene mit fester `id`; geöffnet, gerufen und ausgeblendet
/// wird er nur über diese Funktionen bzw. `LoomnCompanionButton`.
@MainActor
public enum LoomnCompanion {
    /// Wird nach jedem Öffnen gesendet (`object`: `sizeKey` des Kompagnons)
    public static let opened = Notification.Name("loomn.kompagnon.geoeffnet")

    /// Öffnen bzw. nach vorn holen, immer aufgeklappt
    public static func open(_ openWindow: OpenWindowAction, id: String, fold: LoomnFold) {
        openWindow(id: id)
        DispatchQueue.main.async { NotificationCenter.default.post(name: opened, object: fold.style.sizeKey) }
    }

    /// Ausblenden (das Fenster wird geschlossen; die gemerkte Größe bleibt)
    public static func hide(_ dismissWindow: DismissWindowAction, id: String) {
        dismissWindow(id: id)
    }

    /// Zurückholen: oben rechts ins Hauptfenster (oder auf den Hauptbildschirm), z. B. wenn er auf einem
    /// anderen Bildschirm liegt
    public static func recall(_ fold: LoomnFold, into main: NSWindow?) {
        guard let c = fold.window else { return }
        let target = main.flatMap { $0.isVisible ? $0.frame : nil } ?? NSScreen.main?.visibleFrame ?? c.frame
        c.setFrameOrigin(NSPoint(x: target.maxX - c.frame.width - 24, y: target.maxY - c.frame.height - 72))
        c.orderFrontRegardless()
    }
}

/// Knopf fürs Hauptfenster: öffnet den Kompagnon, zweiter Klick blendet ihn aus. Orange, solange er offen ist.
/// Lange drücken holt ihn ins Hauptfenster zurück.
public struct LoomnCompanionButton: View {
    @ObservedObject private var fold: LoomnFold
    private let id: String
    private let title: String
    private let symbol: String
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var longPressed = false
    @State private var main: NSWindow?

    public init(_ fold: LoomnFold, id: String, title: String = "Kompagnon", symbol: String = "pip") {
        self.fold = fold
        self.id = id
        self.title = title
        self.symbol = symbol
    }

    public var body: some View {
        let on = fold.isOpen
        Button {
            // Nach langem Drücken nicht zusätzlich schließen
            if longPressed { longPressed = false; return }
            if on { LoomnCompanion.hide(dismissWindow, id: id) } else { LoomnCompanion.open(openWindow, id: id, fold: fold) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(title)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(on ? Color(fold.style.background) : Color.primary)
            .background(on ? Color(fold.style.accent) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            longPressed = true
            if !on { LoomnCompanion.open(openWindow, id: id, fold: fold) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (on ? 0 : 0.3)) { LoomnCompanion.recall(fold, into: main) }
        })
        .background(LoomnWindowReader { w in if main !== w { main = w } })
        .fixedSize()
        .help("Kleines Fenster, das über allen Apps bleibt. Lange drücken holt es hierher zurück.")
    }
}

// MARK: - Animation

/// Animation in einem eigenen, durchsichtigen Fenster über allem: Bild des Fensters, darüber Orange mit
/// Zeichen. Beide ändern gemeinsam ihre Größe, während das Orange ein- bzw. ausblendet.
@MainActor
final class LoomnFoldMorph {
    private let overlay: NSWindow
    private let shot = CALayer()
    private let orange = CALayer()
    private let markLayer = CALayer()
    private let origin: CGPoint
    private let duration: Double

    init(fold: LoomnFold, from frame: NSRect, snapshot: CGImage?, orange start: Float) {
        let style = fold.style
        duration = style.duration
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
            l.cornerRadius = style.radius
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.contentsScale = scale
            view.layer?.addSublayer(l)
        }
        shot.contentsGravity = .topLeft
        shot.backgroundColor = style.background.cgColor
        shot.contents = snapshot
        orange.backgroundColor = style.accent.cgColor
        orange.opacity = start
        markLayer.bounds = CGRect(x: 0, y: 0, width: style.bubbleSize, height: style.bubbleSize)
        markLayer.position = CGPoint(x: local.midX, y: local.midY)
        markLayer.contentsGravity = .center
        markLayer.contentsScale = scale
        let r = ImageRenderer(content: fold.mark.frame(width: style.bubbleSize, height: style.bubbleSize))
        r.scale = scale
        markLayer.contents = r.cgImage
        markLayer.opacity = start
        view.layer?.addSublayer(markLayer)
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

    /// Größe und Orange zusammen; danach ist das Animationsfenster weg
    func run(to frame: NSRect, orange end: Float, done: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Hält sich selbst bis zum Ende (sonst wäre das Fenster der Animation sofort weg)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                withExtendedLifetime(self) {
                    done()
                    DispatchQueue.main.async { [overlay] in overlay.orderOut(nil) }
                }
            }
        }
        let local = Self.local(frame, origin)
        for l in [shot, orange] {
            animate(l, "bounds", NSValue(rect: CGRect(origin: .zero, size: local.size)))
            animate(l, "position", NSValue(point: CGPoint(x: local.midX, y: local.midY)))
        }
        animate(markLayer, "position", NSValue(point: CGPoint(x: local.midX, y: local.midY)))
        animate(orange, "opacity", end as NSNumber)
        animate(markLayer, "opacity", end as NSNumber)
        CATransaction.commit()
    }

    private func animate(_ l: CALayer, _ key: String, _ to: Any) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.setValue(to, forKeyPath: key)
        l.add(a, forKey: key)
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
}
