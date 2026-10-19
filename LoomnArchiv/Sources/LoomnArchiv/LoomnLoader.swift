import AppKit
import SwiftUI

/// Ladesymbol wie in Loomn Cam: der Loomn-Schriftzug schreibt sich, steht, schreibt sich weg.
/// Bilder: Contents/Resources/Loader/loomn_wNN.png und loomn_eNN.png (weiß mit Alpha).
struct LoomnLoader: View {
    var color: Color = DS.text
    var width: CGFloat = 120

    private static let write = frames("w", 32)
    private static let erase = frames("e", 28)
    private static let writeTime = 1.0, holdTime = 0.45, eraseTime = 0.8, gapTime = 0.2
    private static let cycle = writeTime + holdTime + eraseTime + gapTime

    private static func frames(_ kind: String, _ count: Int) -> [NSImage] {
        let dir = Bundle.main.resourceURL?.appendingPathComponent("Loader")
        return (0..<count).compactMap { i in
            guard let url = dir?.appendingPathComponent(String(format: "loomn_%@%02d.png", kind, i)) else { return nil }
            let img = NSImage(contentsOf: url)
            img?.isTemplate = true
            return img
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let s = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
            Group {
                if let img = Self.image(at: s) {
                    Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .foregroundStyle(color)
            .frame(width: width, height: width * 0.6)
        }
    }

    private static func image(at s: Double) -> NSImage? {
        guard let last = write.last else { return nil }
        if s < writeTime { return write[min(Int(s / writeTime * Double(write.count)), write.count - 1)] }
        if s < writeTime + holdTime { return last }
        let e = s - writeTime - holdTime
        if e < eraseTime { return erase[min(Int(e / eraseTime * Double(erase.count)), erase.count - 1)] }
        return nil
    }
}
