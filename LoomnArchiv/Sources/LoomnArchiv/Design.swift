import AppKit
import CoreText
import SwiftUI

/// Gestaltung wie Loomn Cam (LiveShared/Design.swift): ein Raster, Barlow Condensed, Signalorange.
/// Werte bewusst identisch halten, damit beide Werkzeuge gleich aussehen.
enum DS {
    // Raster
    static let gap: CGFloat = 8
    static let margin: CGFloat = 16
    /// Eine Höhe für alle Knöpfe, Felder, Filter und Chips (wie in allen Loomn-Tools)
    static let control: CGFloat = 40
    static let primary: CGFloat = 52
    static let radius: CGFloat = 8
    static let stroke: CGFloat = 3

    // Farben
    static let bg = Color(red: 0.078, green: 0.078, blue: 0.078)
    static let surface = Color(red: 0.133, green: 0.129, blue: 0.125)
    static let surfaceHi = Color(red: 0.180, green: 0.176, blue: 0.169)
    static let line = Color(red: 0.227, green: 0.224, blue: 0.212)
    static let text = Color(red: 0.941, green: 0.933, blue: 0.914)
    static let dim = Color(red: 0.549, green: 0.537, blue: 0.518)
    static let accent = Color(red: 1.0, green: 0.353, blue: 0.122)   // Signalorange
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.0)
    static let error = Color(red: 1.0, green: 0.27, blue: 0.27)

    enum Weight: String {
        case regular = "BarlowCondensed-Medium", semibold = "BarlowCondensed-SemiBold", bold = "BarlowCondensed-Bold"
    }

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        fontsReady ? .custom(weight.rawValue, fixedSize: size) : .system(size: size * 0.9, weight: weight == .regular ? .medium : .bold).width(.condensed)
    }

    static let label = font(13, .semibold)
    static let body = font(18, .bold)
    static let value = font(24, .bold)
    static let big = font(40, .bold)
    /// Eine Schrift für alle Bedienelemente
    static let controlFont = font(17, .semibold)

    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// Schriften aus Contents/Resources/Fonts registrieren (App-Bundle).
    private(set) static var fontsReady = false
    static func registerFonts() {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                    Bundle.main.bundleURL.appendingPathComponent("Resources/Fonts")].compactMap { $0 }
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "ttf" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
        }
        fontsReady = NSFont(name: Weight.bold.rawValue, size: 12) != nil
    }
}

/// Einzelne Zeile in einer Vorschlags- oder Auswahlliste: unter der Maus (oder per Pfeiltaste
/// markiert) wird sie leicht dunkel hinterlegt, damit jeder Treffer als eigenes Feld erkennbar ist.
struct ListRowHover: ViewModifier {
    /// Von außen markiert (Pfeiltasten); nil = nur Maus
    var marked: Bool?
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(Color.black.opacity((marked ?? hover) ? 0.32 : 0), in: DS.shape)
            .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}

extension View {
    func listRowHover(marked: Bool? = nil) -> some View { modifier(ListRowHover(marked: marked)) }
}

extension View {
    /// Versalien-Beschriftung mit Sperrung.
    func dsLabel(_ color: Color = DS.dim) -> some View {
        self.font(DS.label).tracking(1.6).textCase(.uppercase).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.6).allowsTightening(true)
    }
}

// MARK: - Bausteine (wie Shared/Components.swift in Loomn Cam)

struct DSButton: View {
    var title: String?
    var icon: String?
    var active = false
    var fill: Color?
    var height: CGFloat = DS.control
    var action: () -> Void

    init(_ title: String? = nil, icon: String? = nil, active: Bool = false, fill: Color? = nil,
         height: CGFloat = DS.control, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.active = active
        self.fill = fill
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                if let title { Text(title).font(DS.body).tracking(0.8).textCase(.uppercase) }
            }
            // Nie mit „…“ kürzen, lieber kleiner
            .lineLimit(1).minimumScaleFactor(0.5).allowsTightening(true)
            .monospacedDigit()
            .foregroundStyle(active || fill != nil ? DS.bg : DS.text)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(active ? DS.accent : (fill ?? DS.surface), in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
    }
}

struct DSPress: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
    }
}

/// Auswahl aus wenigen Werten: gleich breite Knöpfe in einer Reihe.
struct DSSegment<T: Hashable>: View {
    var title: String
    var options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).dsLabel()
            HStack(spacing: DS.gap) {
                ForEach(options.indices, id: \.self) { i in
                    DSButton(options[i].1, active: selection == options[i].0) { selection = options[i].0 }
                }
            }
        }
    }
}

struct Badge: View {
    var text: String
    var tint: Color?
    var small = false

    init(_ text: String, tint: Color? = nil, small: Bool = false) {
        self.text = text
        self.tint = tint
        self.small = small
    }

    var body: some View {
        Text(text)
            .font(small ? DS.font(11, .semibold) : DS.label).tracking(small ? 0.6 : 1.4).textCase(.uppercase).monospacedDigit()
            .lineLimit(1).fixedSize()
            .foregroundStyle(tint == nil ? DS.text : DS.bg)
            .padding(.horizontal, small ? 5 : 8)
            .frame(height: small ? 17 : 22)
            .background(tint ?? DS.surfaceHi, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Fortschrittsbalken: Linie in Signalorange.
struct DSProgress: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.line)
                Rectangle().fill(DS.accent).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: DS.stroke)
    }
}
