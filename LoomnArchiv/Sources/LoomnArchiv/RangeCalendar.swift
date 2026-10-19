import SwiftUI

/// Zeitraum direkt im Kalender wählen: erster Klick Anfang, zweiter Klick Ende,
/// dritter Klick fängt neu an. Ein einzelner Tag nochmal angeklickt: Zeitraum weg.
/// Tage mit Videos haben einen Punkt.
struct RangeCalendar: View {
    @Binding var from: Date?
    @Binding var to: Date?
    var marked: Set<Date> = []
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start
    /// Anfang gesetzt, Ende noch offen
    @State private var waitingForEnd = false

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "de_DE")
        c.firstWeekday = 2
        return c
    }

    private static let monthTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                arrow("chevron.left", -1)
                Text(Self.monthTitle.string(from: month)).font(DS.font(18, .bold)).frame(maxWidth: .infinity)
                arrow("chevron.right", 1)
            }
            HStack(spacing: 0) {
                ForEach(["M", "D", "M", "D", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "D", "M", "D", "F", "S", "S"][i]).dsLabel().frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { d in cell(d) }
            }
            Text(summary).dsLabel(from == nil ? DS.dim : DS.accent).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(DS.surface.opacity(0.6), in: DS.shape)
        .onAppear { if let from { month = cal.dateInterval(of: .month, for: from)?.start ?? month } }
        .onChange(of: from) { _, f in
            if let f, !waitingForEnd { month = cal.dateInterval(of: .month, for: f)?.start ?? month }
        }
    }

    /// 6 Wochen ab dem Montag vor dem Monatsersten
    private var days: [Date] {
        let weekday = cal.component(.weekday, from: month)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: month)!
        return (0..<42).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    private var rangeStart: Date? { from.map { cal.startOfDay(for: $0) } }
    private var rangeEnd: Date? {
        guard from != nil else { return nil }
        return cal.startOfDay(for: to ?? (waitingForEnd ? from! : Date()))
    }

    private var summary: String {
        guard let s = rangeStart, let e = rangeEnd else { return "Kein Zeitraum" }
        if waitingForEnd { return "Ab \(Self.short.string(from: s)), Ende anklicken" }
        if s == e { return Self.short.string(from: s) }
        return "\(Self.short.string(from: s)) bis \(to == nil ? "heute" : Self.short.string(from: e))"
    }

    private func arrow(_ icon: String, _ step: Int) -> some View {
        Button { withAnimation(.smooth(duration: 0.2)) { month = cal.date(byAdding: .month, value: step, to: month)! } } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .frame(width: DS.control, height: 32).background(DS.surface, in: DS.shape).contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
    }

    private func cell(_ d: Date) -> some View {
        let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
        let isStart = rangeStart == d
        let isEnd = rangeEnd == d
        let inside = rangeStart.map { $0 <= d } == true && rangeEnd.map { d <= $0 } == true
        let edge = isStart || isEnd
        let today = cal.isDateInToday(d)
        return Button { tap(d) } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: d))")
                    .font(DS.font(16, edge || today ? .bold : .semibold))
                Circle().fill(marked.contains(d) ? (edge ? DS.bg : DS.accent) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundStyle(edge ? DS.bg : today ? DS.accent : inMonth ? DS.text : DS.dim.opacity(0.6))
            .background(edge ? DS.accent : inside ? DS.accent.opacity(0.18) : .clear, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
    }

    private func tap(_ d: Date) {
        if waitingForEnd, let s = rangeStart {
            if d < s { from = d; to = s } else { to = d }
            waitingForEnd = false
        } else if let s = rangeStart, s == rangeEnd, s == d {
            from = nil; to = nil
        } else {
            from = d; to = d
            waitingForEnd = true
        }
    }
}
