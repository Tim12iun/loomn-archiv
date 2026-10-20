import AppKit
import SwiftUI

/// Andocken des Kompagnons an ein Tool (archivn-Seite von `LoomnAndocken.swift`, Fassung 2).
/// Das eingeklappte Viereck aufs orange Ziel eines Tools ziehen: Der Kompagnon legt sich randlos auf den
/// gemeldeten Bereich, läuft mit, folgt Ebene und Sichtbarkeit des Tool-Fensters und lässt sich wieder lösen
/// (Knopf, Kopfleiste herausziehen oder das Viereck auf dem Ziel herausziehen).
/// `angedockt` geht erst nach der Andock-Animation raus, `geloest` erst nach dem Einsaugen ins Viereck.
/// Angedockt wird nicht gespeichert: nach einem Neustart ist der Kompagnon frei.
@MainActor
final class CompanionDock: ObservableObject {
    static let shared = CompanionDock()

    /// Andockstelle, an der der Kompagnon gerade liegt (auch schon während der Andock-Animation)
    @Published private(set) var docked: LoomnAndocken.Platz?
    /// Tool-Fenster wird verschoben oder gezogen: Orange liegt über dem Kompagnon
    @Published private(set) var moving = false

    /// Vom Kompagnon gesetzt: auf die Stelle aufklappen (danach `dockFinished`), ins Viereck einsaugen
    /// (danach den Abschluss aufrufen) bzw. ohne Animation wieder zum Viereck werden
    var onDock: ((LoomnAndocken.Platz) -> Void)?
    var onRelease: ((NSRect, @escaping () -> Void) -> Void)?
    var onGone: ((NSPoint?) -> Void)?

    private var verzeichnis: LoomnAndocken.Verzeichnis?
    /// Ziel, das das gezogene Viereck gerade berührt
    private var hovering: LoomnAndocken.Platz?
    /// Nächste Andockstelle in Reichweite und zuletzt gemeldete Nähe
    private var near: LoomnAndocken.Platz?
    private var sentNaehe: Double?
    private var sentState: String?
    /// Wo das Viereck frei lag, bevor es angedockt wurde
    private var freeOrigin: NSPoint?
    private var vorn: Bool?
    /// Animation läuft: `angedockt` noch nicht gemeldet
    private var settling = false
    private let handle = DockHandle()

    /// Wo das orange Viereck zum Lösen liegt: auf dem Ziel, wenn es im Bereich liegt (neuere Tools),
    /// sonst oben rechts in der Kopfleiste des Kompagnons
    static func handleRect(_ p: LoomnAndocken.Platz) -> NSRect {
        let b = p.bereich.rect, z = p.ziel.rect
        if b.contains(z) { return z }
        let s: CGFloat = 24
        return NSRect(x: b.maxX - 12 - s, y: b.maxY - 19 - s / 2, width: s, height: s)
    }

    func start() {
        guard verzeichnis == nil, Screenshots.requested == nil else { return }
        let v = LoomnAndocken.Verzeichnis()
        v.beiPlatz = { [weak self] p in self?.update(p) }
        v.beiWeg = { [weak self] prozess, fenster in self?.gone(prozess, fenster) }
        verzeichnis = v
        handle.onRelease = { [weak self] r in self?.releaseFromHandle(to: r) }
    }

    /// Alle Tools um ihre Andockstellen bitten (beim Einklappen)
    func ask() { verzeichnis?.frage() }

    func isDocked(_ w: NSWindow) -> Bool { docked != nil && w === WindowFinder.companion }

    // MARK: Viereck ziehen

    func bubbleDragBegan(at origin: NSPoint) {
        freeOrigin = origin
        ask()
    }

    /// Bei jeder Bewegung: berührt das Viereck ein Ziel, schwebt es; der nächsten Stelle in Reichweite
    /// wird gemeldet, wie nah es ist (das Tool lässt sein Ziel entsprechend aufleuchten).
    func bubbleMoved(frame r: NSRect) {
        guard let v = verzeichnis else { return }
        let touched = v.ziel(beruehrt: r)
        let nearest = touched ?? v.plaetze.values.filter(\.sichtbar)
            .min { LoomnAndocken.Verzeichnis.abstand(r, $0.ziel.rect) < LoomnAndocken.Verzeichnis.abstand(r, $1.ziel.rect) }
        let n = touched != nil ? 1 : nearest.map { v.naehe(von: r, zu: $0) } ?? 0
        let target = n > 0 ? nearest : nil
        if let old = near, !same(old, target) {
            v.melde(LoomnAndocken.geloest, an: old, naehe: 0)
            sentNaehe = nil
            sentState = nil
        }
        near = target
        hovering = touched
        guard let t = target else { return }
        let state = touched != nil ? LoomnAndocken.schwebt : LoomnAndocken.geloest
        if state != sentState || abs(n - (sentNaehe ?? -1)) >= 0.015 {
            v.melde(state, an: t, naehe: n * n)
            sentNaehe = n
            sentState = state
        }
    }

    /// Losgelassen: true, wenn auf einem Ziel angedockt wird. Bis die Animation fertig ist, bleibt es bei `schwebt`.
    func bubbleDropped() -> Bool {
        let t = hovering
        if let n = near, !same(n, t) { verzeichnis?.melde(LoomnAndocken.geloest, an: n) }
        hovering = nil
        near = nil
        sentNaehe = nil
        sentState = nil
        guard let t else { return false }
        verzeichnis?.melde(LoomnAndocken.schwebt, an: t)
        docked = t
        vorn = nil
        settling = true
        onDock?(t)
        return true
    }

    /// Andock-Animation fertig, Kompagnon zu sehen
    func dockFinished() {
        settling = false
        guard let p = docked else { return }
        verzeichnis?.melde(LoomnAndocken.angedockt, an: p)
        if let w = WindowFinder.companion { handle.show(p, above: w, flash: true) }
    }

    // MARK: Angedockt

    /// Fensterart fürs Andocken: randlos, ohne Schatten und Knöpfe, genau auf dem Bereich
    func applyDocked(_ w: NSWindow) {
        guard let p = docked else { return }
        w.hasShadow = false
        w.isOpaque = false
        w.backgroundColor = .clear
        CompanionFold.chrome(w, collapsed: true)
        w.contentMinSize = NSSize(width: 64, height: 16)
        roundCorners(w, CGFloat(p.ecken))
        if w.frame != p.bereich.rect { w.setFrame(p.bereich.rect, display: true) }
        arrange(w, p, force: true)
    }

    /// Lösen geht nur über das orange Viereck (Klick oder Herausziehen) oder durch Beenden von archivn
    private func release(_ w: NSWindow, to target: NSRect, keepHandle: Bool = false) {
        guard let p = docked, !settling else { return }
        if !keepHandle { handle.hide() }
        // Animation zuerst (nimmt das Bild mit den Ecken des Bereichs), dann das unsichtbare Fenster lösen
        onRelease?(target) { [weak self] in
            self?.handle.hide()
            self?.verzeichnis?.melde(LoomnAndocken.geloest, an: p)
        }
        undock(w)
    }

    /// Viereck angeklickt oder herausgezogen: Kompagnon wird in dieses Viereck gesogen
    private func releaseFromHandle(to r: NSRect) {
        guard let w = WindowFinder.companion else { return }
        release(w, to: r, keepHandle: true)
    }

    /// Ecken des Andockbereichs am Fenster selbst runden (nicht in SwiftUI, siehe CompanionView)
    private func roundCorners(_ w: NSWindow, _ r: CGFloat) {
        guard let v = w.contentView else { return }
        v.wantsLayer = true
        v.layer?.cornerRadius = r
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = r > 0
    }

    /// Fenster wieder frei (ohne Meldung, die kommt nach der Animation)
    private func undock(_ w: NSWindow) {
        docked = nil
        moving = false
        vorn = nil
        settling = false
        w.hasShadow = true
        w.isOpaque = true
        w.backgroundColor = NSColor(DS.bg)
        roundCorners(w, 0)
        w.level = .floating
    }

    private func update(_ p: LoomnAndocken.Platz) {
        if let h = hovering, same(h, p) { hovering = p }
        if let n = near, same(n, p) { near = p }
        guard let d = docked, same(d, p), let w = WindowFinder.companion else { return }
        docked = p
        if (p.bewegt ?? false) != moving { moving = p.bewegt ?? false }
        if w.frame != p.bereich.rect { w.setFrame(p.bereich.rect, display: true) }
        arrange(w, p, force: false)
        if !settling { handle.follow(p, above: w) }
    }

    /// Ebene und Sichtbarkeit wie das Tool-Fenster: Tool vorn → über allem, sonst direkt über dem Tool
    private func arrange(_ w: NSWindow, _ p: LoomnAndocken.Platz, force: Bool) {
        guard p.sichtbar else {
            if w.isVisible { w.orderOut(nil) }
            vorn = nil
            return
        }
        guard force || !w.isVisible || vorn != p.vorn else { return }
        vorn = p.vorn
        if p.vorn {
            w.level = .floating
            w.orderFrontRegardless()
        } else {
            w.level = .normal
            w.order(.above, relativeTo: p.fenster)
        }
    }

    private func gone(_ prozess: Int32, _ fenster: Int) {
        if let h = hovering, h.prozess == prozess, h.fenster == fenster { hovering = nil }
        if let n = near, n.prozess == prozess, n.fenster == fenster { near = nil }
        guard let d = docked, d.prozess == prozess, d.fenster == fenster, let w = WindowFinder.companion else { return }
        handle.hide()
        undock(w)
        onGone?(freeOrigin)
    }

    private func same(_ a: LoomnAndocken.Platz?, _ b: LoomnAndocken.Platz?) -> Bool {
        a?.prozess == b?.prozess && a?.fenster == b?.fenster
    }
}

/// Kleines eigenes Fenster genau auf dem Ziel des Tools, solange angedockt: So bekommt archivn den Klick
/// selbst. Herausziehen löst den Kompagnon, das Viereck wächst dabei mit der Entfernung zur vollen Größe.
@MainActor
final class DockHandle {
    var onRelease: ((NSRect) -> Void)?
    private var window: NSWindow?

    /// `flash`: leuchtet einmal kurz auf (nach dem Andocken: „hier ist das Viereck jetzt“)
    func show(_ p: LoomnAndocken.Platz, above w: NSWindow, flash: Bool = false) {
        let win = window ?? make()
        window = win
        follow(p, above: w)
        if flash { (win.contentView as? HandleView)?.flash() }
    }

    func follow(_ p: LoomnAndocken.Platz, above w: NSWindow) {
        guard let win = window else { return }
        guard p.sichtbar else { if win.isVisible { win.orderOut(nil) }; return }
        let r = CompanionDock.handleRect(p)
        if win.frame != r { win.setFrame(r, display: true) }
        win.level = w.level
        if w.isVisible { win.order(.above, relativeTo: w.windowNumber) }
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func make() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = HandleView()
        v.owner = self
        win.contentView = v
        return win
    }

    /// Klick: wächst auf Viereck-Größe, der Kompagnon wird hineingesogen. Ziehen: folgt der Maus und wächst
    /// mit der Entfernung; weit genug weg loslassen löst, kurz gezogen schnappt es zurück aufs Ziel.
    fileprivate func drag(_ win: NSWindow) {
        let start = NSEvent.mouseLocation
        let home = win.frame
        let full = CompanionFold.size
        var dist: CGFloat = 0
        while let e = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let m = NSEvent.mouseLocation
            dist = max(dist, hypot(m.x - start.x, m.y - start.y))
            if dist > 3 {
                let d = hypot(m.x - start.x, m.y - start.y)
                let t = min(d / 80, 1)
                let w = home.width + (full - home.width) * t, h = home.height + (full - home.height) * t
                let c = NSPoint(x: home.midX + m.x - start.x, y: home.midY + m.y - start.y)
                win.setFrame(NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), display: true)
            }
            if e.type == .leftMouseUp { break }
        }
        let end = NSEvent.mouseLocation
        let away = hypot(end.x - start.x, end.y - start.y)
        if dist > 3 && away <= 24 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(home, display: true)
            }
            return
        }
        let f = win.frame
        let target = CompanionFold.fitted(NSRect(x: f.midX - full / 2, y: f.midY - full / 2, width: full, height: full))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(target, display: true)
        }
        onRelease?(target)
    }

    fileprivate final class HandleView: NSView {
        weak var owner: DockHandle?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); needsDisplay = true }
        private var glow: CGFloat = 0
        private var flashTimer: Timer?

        /// Einmal kurz hell aufleuchten
        func flash() {
            flashTimer?.invalidate()
            let start = Date()
            flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    let x = Date().timeIntervalSince(start) / 0.55
                    self.glow = x >= 1 ? 0 : CGFloat(sin(x * .pi))
                    self.needsDisplay = true
                    if x >= 1 { t.invalidate() }
                }
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            let r = min(bounds.width, bounds.height) * 0.22
            let path = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
            (NSColor(DS.accent).blended(withFraction: glow * 0.55, of: .white) ?? NSColor(DS.accent)).setFill()
            path.fill()
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            owner?.drag(window)
        }
    }
}
