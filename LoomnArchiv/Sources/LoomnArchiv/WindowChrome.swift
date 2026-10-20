import AppKit
import SwiftUI

/// Freie Fläche, die sich wie eine Titelleiste verhält: ziehen verschiebt das Fenster,
/// Doppelklick zoomt (an die Bildschirmränder, kein Vollbild) bzw. stellt die Größe wieder her.
/// Die Systemeinstellung „Doppelklick auf Titelleiste“ wird beachtet. Liegt immer hinter Knöpfen.
struct WindowDragArea: NSViewRepresentable {
    /// false: nur verschieben (Griff-Streifen am Rand), true: zusätzlich Doppelklick wie Titelleiste
    var titleBar = true
    /// Eigener Doppelklick statt Zoomen (Kompagnon: einklappen)
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        // Mit eigenem Doppelklick (Kompagnon) selbst verschieben: so greift das Andocken von macOS nicht
        DragView(titleBar: titleBar, onDoubleClick: onDoubleClick, manual: onDoubleClick != nil)
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? DragView)?.titleBar = titleBar
        (v as? DragView)?.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var titleBar: Bool
        var onDoubleClick: (() -> Void)?
        let manual: Bool
        init(titleBar: Bool, onDoubleClick: (() -> Void)?, manual: Bool) {
            self.titleBar = titleBar
            self.onDoubleClick = onDoubleClick
            self.manual = manual
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { !manual }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if titleBar, event.clickCount == 2 {
                if let onDoubleClick { onDoubleClick() } else { Self.doubleClick(window) }
            } else if manual {
                Self.move(window)
            } else {
                window.performDrag(with: event)
            }
        }

        /// Fenster selbst mit der Maus mitführen, ohne das Verschieben von macOS
        /// (das würde am Bildschirmrand das Andocken bzw. Kacheln auslösen)
        static func move(_ window: NSWindow) {
            let dock = CompanionDock.shared
            // Angedockt liegt der Kompagnon fest; lösen geht nur über das orange Viereck
            if dock.isDocked(window) { return }
            let start = NSEvent.mouseLocation
            let origin = window.frame.origin
            var p = start
            // Freier, aufgeklappter Kompagnon lässt sich auch direkt andocken (Mauszeiger aufs Ziel)
            let canDock = window === WindowFinder.companion && !dock.isDocked(window)
            if canDock { dock.bubbleDragBegan(at: origin) }
            while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                p = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
                if canDock {
                    let s = CompanionFold.size
                    dock.bubbleMoved(frame: NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
                }
                if e.type == .leftMouseUp { break }
            }
            if canDock { _ = dock.bubbleDropped() }
        }

        static func doubleClick(_ w: NSWindow) {
            let d = UserDefaults.standard
            switch d.string(forKey: "AppleActionOnDoubleClick") {
            case "None": return
            case "Minimize": w.miniaturize(nil)
            case "Maximize", "Fill": w.zoom(nil)
            default:
                if d.object(forKey: "AppleMiniaturizeOnDoubleClick") != nil, d.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
                    w.miniaturize(nil)
                } else {
                    w.zoom(nil)
                }
            }
        }
    }
}

enum WindowGrip {
    /// Breite des Griff-Rands links, rechts und unten
    static let width: CGFloat = 12
}

extension View {
    /// Fläche, die bis an den Fensterrand reicht: die Farbe läuft unter dem Griff-Rand weiter,
    /// damit der Rand unsichtbar ist. Fängt keine Klicks ab, der Griff darunter bleibt nutzbar.
    func bleed(_ color: Color, _ edges: Edge.Set) -> some View {
        background(color.padding(edges, -WindowGrip.width).allowsHitTesting(false))
    }

    /// Schmale Griff-Streifen links, rechts und unten im leeren Rand um die Oberfläche (zum Verschieben,
    /// auch wenn das Fenster halb aus dem Bildschirm ragt). Ganz außen bleibt das normale Größe-Ändern.
    func windowGripMargin(_ width: CGFloat = WindowGrip.width) -> some View {
        // Die äußersten 4 pt bleiben frei fürs Größe-Ändern, der Streifen liegt knapp innerhalb
        let edge: CGFloat = 4
        return self
            .padding([.leading, .trailing, .bottom], width)
            .background(alignment: .leading) { WindowDragArea(titleBar: false).frame(width: width - edge).padding(.leading, edge) }
            .background(alignment: .trailing) { WindowDragArea(titleBar: false).frame(width: width - edge).padding(.trailing, edge) }
            .background(alignment: .bottom) { WindowDragArea(titleBar: false).frame(height: width - edge).padding(.bottom, edge) }
    }
}
