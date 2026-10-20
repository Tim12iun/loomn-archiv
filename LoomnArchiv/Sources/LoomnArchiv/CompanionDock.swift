import AppKit
import SwiftUI

/// Andocken des Kompagnons an ein Tool (archivn-Seite von `LoomnAndocken.swift`).
/// Das eingeklappte Viereck aufs orange Ziel eines Tools ziehen: Der Kompagnon legt sich randlos auf den
/// gemeldeten Bereich, läuft mit, folgt Ebene und Sichtbarkeit des Tool-Fensters und lässt sich wieder lösen.
/// Angedockt wird nicht gespeichert: nach einem Neustart ist der Kompagnon frei.
@MainActor
final class CompanionDock: ObservableObject {
    static let shared = CompanionDock()

    /// Andockstelle, an der der Kompagnon gerade liegt
    @Published private(set) var docked: LoomnAndocken.Platz?
    /// Tool-Fenster wird verschoben oder gezogen: Orange liegt über dem Kompagnon
    @Published private(set) var moving = false

    /// Vom Kompagnon gesetzt: auf die Stelle aufklappen bzw. wieder zum Viereck werden
    var onDock: ((LoomnAndocken.Platz) -> Void)?
    var onGone: ((NSPoint?) -> Void)?

    private var verzeichnis: LoomnAndocken.Verzeichnis?
    private var hovering: LoomnAndocken.Platz?
    /// Wo das Viereck frei lag, bevor es angedockt wurde
    private var freeOrigin: NSPoint?
    private var vorn: Bool?

    func start() {
        guard verzeichnis == nil, Screenshots.requested == nil else { return }
        let v = LoomnAndocken.Verzeichnis()
        v.beiPlatz = { [weak self] p in self?.update(p) }
        v.beiWeg = { [weak self] prozess, fenster in self?.gone(prozess, fenster) }
        verzeichnis = v
    }

    /// Alle Tools um ihre Andockstellen bitten (beim Einklappen)
    func ask() { verzeichnis?.frage() }

    func isDocked(_ w: NSWindow) -> Bool { docked != nil && w === WindowFinder.companion }

    // MARK: Viereck ziehen

    func bubbleDragBegan(at origin: NSPoint) { freeOrigin = origin }

    /// Bei jeder Bewegung: liegt die Mitte des Vierecks über einem Ziel, leuchtet es im Tool auf
    func bubbleMoved(center: NSPoint) {
        let t = verzeichnis?.ziel(bei: center)
        guard !same(t, hovering) else { return }
        if let h = hovering { verzeichnis?.melde(LoomnAndocken.geloest, an: h) }
        if let t { verzeichnis?.melde(LoomnAndocken.schwebt, an: t) }
        hovering = t
    }

    /// Losgelassen: true, wenn auf einem Ziel angedockt wird
    func bubbleDropped() -> Bool {
        guard let t = hovering else { return false }
        hovering = nil
        docked = t
        vorn = nil
        verzeichnis?.melde(LoomnAndocken.angedockt, an: t)
        onDock?(t)
        return true
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
        if w.frame != p.bereich.rect { w.setFrame(p.bereich.rect, display: true) }
        arrange(w, p, force: true)
    }

    /// Lösen: wieder frei schwebend, aufgeklappt in der gemerkten Größe
    func release(_ w: NSWindow) {
        guard let p = docked else { return }
        let top = NSPoint(x: w.frame.minX, y: w.frame.maxY)
        undock(w)
        let s = CompanionFold.lastSize
        w.setFrame(CompanionFold.fitted(NSRect(x: top.x, y: top.y - s.height, width: s.width, height: s.height)), display: true)
        _ = p
    }

    /// Kopfleiste angedockt gezogen: weit genug raus löst, sonst zurück auf den Bereich
    func headerDragEnded(_ w: NSWindow, distance: CGFloat) {
        guard let p = docked else { return }
        if distance > 24 { release(w) } else { w.setFrame(p.bereich.rect, display: true) }
    }

    /// Vor dem Einklappen aus dem angedockten Zustand
    func undockForCollapse(_ w: NSWindow) {
        guard docked != nil else { return }
        undock(w)
    }

    private func undock(_ w: NSWindow) {
        if let p = docked { verzeichnis?.melde(LoomnAndocken.geloest, an: p) }
        docked = nil
        moving = false
        vorn = nil
        w.hasShadow = true
        w.isOpaque = true
        w.backgroundColor = NSColor(DS.bg)
        w.level = .floating
        CompanionFold.chrome(w, collapsed: false)
        if !w.isVisible { w.orderFrontRegardless() }
    }

    private func update(_ p: LoomnAndocken.Platz) {
        if let h = hovering, same(h, p) { hovering = p }
        guard let d = docked, same(d, p), let w = WindowFinder.companion else { return }
        docked = p
        if (p.bewegt ?? false) != moving { moving = p.bewegt ?? false }
        if w.frame != p.bereich.rect { w.setFrame(p.bereich.rect, display: true) }
        arrange(w, p, force: false)
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
        guard let d = docked, d.prozess == prozess, d.fenster == fenster, let w = WindowFinder.companion else { return }
        undock(w)
        onGone?(freeOrigin)
    }

    private func same(_ a: LoomnAndocken.Platz?, _ b: LoomnAndocken.Platz?) -> Bool {
        a?.prozess == b?.prozess && a?.fenster == b?.fenster
    }
}
