import AppKit
import SwiftUI

/// Freie Fläche, die sich wie eine Titelleiste verhält: ziehen verschiebt das Fenster,
/// Doppelklick zoomt (an die Bildschirmränder, kein Vollbild) bzw. stellt die Größe wieder her.
/// Die Systemeinstellung „Doppelklick auf Titelleiste“ wird beachtet. Liegt immer hinter Knöpfen.
struct WindowDragArea: NSViewRepresentable {
    /// false: nur verschieben (Griff-Streifen am Rand), true: zusätzlich Doppelklick wie Titelleiste
    var titleBar = true

    func makeNSView(context: Context) -> NSView { DragView(titleBar: titleBar) }
    func updateNSView(_ v: NSView, context: Context) { (v as? DragView)?.titleBar = titleBar }

    final class DragView: NSView {
        var titleBar: Bool
        init(titleBar: Bool) { self.titleBar = titleBar; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if titleBar, event.clickCount == 2 {
                Self.doubleClick(window)
            } else {
                window.performDrag(with: event)
            }
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

extension View {
    /// Schmale Griff-Streifen links, rechts und unten im leeren Rand um die Oberfläche (zum Verschieben,
    /// auch wenn das Fenster halb aus dem Bildschirm ragt). Ganz außen bleibt das normale Größe-Ändern.
    func windowGripMargin(_ width: CGFloat = 12) -> some View {
        // Die äußersten 4 pt bleiben frei fürs Größe-Ändern, der Streifen liegt knapp innerhalb
        let edge: CGFloat = 4
        return self
            .padding([.leading, .trailing, .bottom], width)
            .background(alignment: .leading) { WindowDragArea(titleBar: false).frame(width: width - edge).padding(.leading, edge) }
            .background(alignment: .trailing) { WindowDragArea(titleBar: false).frame(width: width - edge).padding(.trailing, edge) }
            .background(alignment: .bottom) { WindowDragArea(titleBar: false).frame(height: width - edge).padding(.bottom, edge) }
    }
}
