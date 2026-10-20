import AppKit
import SwiftUI

/// Knopf oben in der Leiste: Auswahl-Modus an/aus. Gilt überall, unabhängig vom gewählten Song.
struct CollectButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let on = model.collecting
        Button { model.collecting.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 14, weight: .semibold))
                Text("Auswahl").font(DS.controlFont)
            }
            .padding(.horizontal, 12)
            .frame(height: DS.control)
            .foregroundStyle(on ? DS.bg : DS.text)
            .background(on ? DS.accent : DS.surface, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .fixedSize()
        .help(on ? "Auswahl beenden" : "Mehrere Videos sammeln, auch aus verschiedenen Songs")
    }
}

/// Stapel unten links: gesammelte Videos als leicht versetzte Karten. Ganzer Stapel lässt sich
/// in andere Apps ziehen (alle Dateien auf einmal). Ab vier Karten wiederholt sich das Muster.
struct VideoStack: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var thumbs: ThumbStore
    @State private var bump = false

    /// Versatz und Drehung je Karte, wiederholt sich alle vier
    private static let pattern: [(x: CGFloat, y: CGFloat, angle: Double)] = [(0, 0, -4), (5, -3, 3), (-3, -6, -1), (6, -8, 5)]
    static let card = CGSize(width: 52, height: 65)

    var body: some View {
        let items = model.stacked
        let shown = Array(items.suffix(4))
        let _ = thumbs.generation
        HStack(spacing: 14) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                    let p = Self.pattern[(items.count - shown.count + i) % Self.pattern.count]
                    poster(r)
                        .frame(width: Self.card.width, height: Self.card.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .rotationEffect(.degrees(p.angle))
                        .offset(x: p.x, y: p.y)
                }
            }
            .frame(width: Self.card.width + 16, height: Self.card.height + 16)
            .scaleEffect(bump ? 1.08 : 1)
            .overlay(StackDragSource(urls: items.compactMap { model.url($0) }.filter { FileManager.default.fileExists(atPath: $0.path) },
                                     image: items.last.flatMap { thumbs.image(Previews.posterPath($0.id)) }))
            .help("Ziehen: alle \(items.count) Videos in eine andere App")
            VStack(alignment: .leading, spacing: 2) {
                Text(items.count == 1 ? "1 Video" : "\(items.count) Videos").font(DS.font(17, .bold))
                Text("Stapel ziehen").dsLabel()
            }
            Spacer(minLength: 0)
            Button { model.stack = [] } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28).background(DS.surface, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(DSPress())
            .help("Stapel leeren")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        // Neue Karte landet: Stapel hüpft kurz
        .onChange(of: model.stack.count) { old, new in
            guard new > old else { return }
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { bump = false }
            }
        }
    }

    @ViewBuilder
    private func poster(_ r: VideoRecord) -> some View {
        if let img = thumbs.image(Previews.posterPath(r.id)) {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            ZStack { DS.surface; Image(systemName: "film").foregroundStyle(DS.line) }
        }
    }
}

/// Zieht mehrere Dateien auf einmal (SwiftUI kann pro Ziehen nur eine)
private struct StackDragSource: NSViewRepresentable {
    var urls: [URL]
    var image: NSImage?

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) {
        v.urls = urls
        v.image = image
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: [URL] = []
        var image: NSImage?
        private var down: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { down = event.locationInWindow }

        override func mouseDragged(with event: NSEvent) {
            guard let d = down, !urls.isEmpty else { return }
            let p = event.locationInWindow
            guard hypot(p.x - d.x, p.y - d.y) > 3 else { return }
            down = nil
            let size = VideoStack.card
            let start = convert(d, from: nil)
            let items = urls.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let off = CGFloat(min(i, 3)) * 4
                item.setDraggingFrame(NSRect(x: start.x - size.width / 2 + off, y: start.y - size.height / 2 - off,
                                             width: size.width, height: size.height),
                                      contents: image ?? NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) { down = nil }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}
