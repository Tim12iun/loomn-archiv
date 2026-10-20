import AppKit
import SwiftUI

/// Zeilenumbrechendes Layout für Knöpfe (Formate, Moods, Tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.gap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// `was`: beim Bearbeiten der bisher gespeicherte Wert, der gerade abgewählt ist (leicht orange)
enum ChipState { case off, on, mixed, was }

/// Kleiner Auswahlknopf. Gemischt (nur ein Teil der Auswahl hat ihn): orange Rahmen.
struct Chip: View {
    var title: String
    var state: ChipState = .off
    var icon: String?
    var height: CGFloat = DS.control
    /// Aktiv orange statt hell (für die Art-Knöpfe RAW, CUT, EDIT, FINAL)
    var accent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                Text(title).font(DS.controlFont).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .foregroundStyle(state == .on ? DS.bg : DS.text)
            .background(state.fill, in: DS.shape)
            .overlay(DS.shape.stroke(state == .mixed ? DS.accent : Color.clear, lineWidth: 2))
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .fixedSize()
    }
}

/// RAW, CUT, EDIT, FINAL als Filterknöpfe. Keiner an = alle zeigen; jeder Klick nimmt eine Art
/// dazu oder wieder weg. Aktive Knöpfe leuchten orange.
struct KindFilter: View {
    var kinds: [ListItem]
    @Binding var selected: Set<String>
    var counts: [String: Int] = [:]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(kinds) { k in
                let on = selected.contains(k.id)
                Button {
                    if on { selected.remove(k.id) } else { selected.insert(k.id) }
                } label: {
                    HStack(spacing: 6) {
                        Text(k.name).font(DS.font(17, .bold)).tracking(0.8)
                        if let n = counts[k.id] { Text("\(n)").font(DS.controlFont).opacity(0.7) }
                    }
                    .frame(width: counts.isEmpty ? 72 : 84, height: DS.control)
                    .foregroundStyle(on ? DS.bg : DS.text)
                    .background(on ? DS.accent : DS.surface, in: DS.shape)
                    .overlay(DS.shape.stroke(on ? DS.accent : DS.line, lineWidth: 1))
                    .shadow(color: on ? DS.accent.opacity(0.45) : .clear, radius: 8)
                    .contentShape(DS.shape)
                }
                .buttonStyle(DSPress())
                .fixedSize()
            }
            if !selected.isEmpty {
                Button { selected = [] } label: { Text("Alle").dsLabel(DS.accent).frame(height: DS.control) }
                    .buttonStyle(.plain).padding(.leading, 4)
            }
        }
    }
}

/// Eingabefeld im Loomn-Stil.
struct DSField: View {
    var placeholder: String
    @Binding var text: String
    var size: CGFloat = 18
    /// Pfeil zum Bestätigen zeigen, sobald etwas getippt ist
    var confirm = false
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.font(size))
            if confirm, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                ConfirmArrow(action: onSubmit)
            }
        }
            .padding(.leading, 12)
            .padding(.trailing, confirm ? 4 : 12)
            .frame(height: DS.control)
            .background(DS.surface, in: DS.shape)
            .overlay(DS.shape.stroke(DS.line, lineWidth: 1))
            .onSubmit(onSubmit)
    }
}

/// Abschnitt mit Versalien-Überschrift.
struct Block<Content: View>: View {
    var title: String
    var trailing: String?
    var required = false
    var missing = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).dsLabel(missing ? DS.accent : DS.dim)
                if required { Text(missing ? "Pflicht" : "✓").dsLabel(missing ? DS.accent : DS.dim) }
                Spacer()
                if let trailing { Text(trailing).dsLabel() }
            }
            content()
        }
    }
}

/// Inline „+ neu“: Knopf, der sich in ein Eingabefeld verwandelt.
struct AddInline: View {
    @EnvironmentObject var model: AppModel
    var title = "+ neu"
    var placeholder: String
    var add: (String) -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focus: Bool

    var body: some View {
        if editing {
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.controlFont)
                    .focused($focus)
                    .onSubmit(commit)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    ConfirmArrow(action: commit)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(width: 210, height: DS.control)
            .background(DS.surfaceHi, in: DS.shape)
            .overlay(DS.shape.stroke(DS.accent, lineWidth: 1))
            .onAppear { focus = true }
            .onChange(of: text) { _, t in model.pendingInput[placeholder] = !t.isEmpty }
            .onExitCommand(perform: cancel)
            // Klick irgendwo anders hin schließt das Feld wieder
            .onClickOutside(perform: cancel)
        } else {
            Chip(title: title) { editing = true }
                .foregroundStyle(DS.dim)
        }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { add(t) }
        close()
    }

    private func cancel() { close() }

    private func close() {
        text = ""
        editing = false
        let key = placeholder
        DispatchQueue.main.async { model.pendingInput[key] = false }
    }
}

/// Kleiner oranger Pfeil im Eingabefeld: übernimmt den Eintrag wie Enter.
struct ConfirmArrow: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.bg)
                .frame(width: 28, height: 28)
                .background(DS.accent, in: DS.shape)
                .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .help("Übernehmen (Enter)")
    }
}

/// Meldet Mausklicks außerhalb der Ansicht (im selben oder einem anderen Fenster).
private struct ClickOutside: ViewModifier {
    /// Bereich nach unten verlängern (z. B. für eine darunter schwebende Liste)
    var extend: CGFloat = 0
    var perform: () -> Void
    @State private var frame: CGRect = .zero
    @State private var monitor: Any?
    @State private var extra: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in frame = f }
            })
            .onChange(of: extend, initial: true) { _, e in extra = e }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                    var inside = false
                    if let h = e.window?.contentView?.bounds.height {
                        let p = CGPoint(x: e.locationInWindow.x, y: h - e.locationInWindow.y)
                        var f = frame
                        f.size.height += extra
                        inside = f.contains(p)
                    }
                    if !inside { DispatchQueue.main.async { perform() } }
                    return e
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    func onClickOutside(extend: CGFloat = 0, perform: @escaping () -> Void) -> some View {
        modifier(ClickOutside(extend: extend, perform: perform))
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Double {
    var clock: String {
        guard isFinite, self >= 0 else { return "–" }
        let s = Int(self.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Date {
    var day: String { formatted(.dateTime.day().month(.twoDigits).year()) }
    var dayTime: String { formatted(.dateTime.day().month(.twoDigits).year().hour().minute()) }
}

/// Ansicht der Video-Abschnitte für die ganze App: Reihe (seitlich scrollen) oder alle untereinander.
/// Wird gemerkt. Die Kacheln behalten dabei ihre Größe.
struct RowGridSwitch: View {
    static let key = "ansicht.alleUntereinander"
    @Binding var grid: Bool

    var body: some View {
        HStack(spacing: 4) {
            item("rectangle.split.3x1", "Als Reihe", on: !grid) { grid = false }
            item("square.grid.3x2", "Alle untereinander", on: grid) { grid = true }
        }
    }

    private func item(_ icon: String, _ help: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold))
                .foregroundStyle(on ? DS.bg : DS.text)
                .frame(width: DS.control, height: DS.control)
                .background(on ? DS.accent : DS.surface, in: DS.shape)
                .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .help(help)
    }
}

extension ChipState {
    var fill: Color {
        switch self {
        case .on: DS.accent
        case .was: DS.accent.opacity(0.28)
        default: DS.surface
        }
    }
}
