import SwiftUI

/// Hinweis oben rechts, wenn eine neue Version bereitliegt. Installiert nur auf Knopfdruck.
/// `inline`: dieselbe Karte direkt in den Einstellungen statt schwebend über dem Hauptfenster.
struct UpdateBanner: View {
    @EnvironmentObject var updater: ToolUpdater
    var inline = false

    var body: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        // Oben rechts im Hauptfenster nur ein neues Update (und dessen Installation).
        // „Suche läuft“, „ist aktuell“ und Fehler stehen nur in den Einstellungen.
        case .checking where !inline, .failed where !inline:
            EmptyView()
        case .checking:
            card {
                HStack(spacing: 12) {
                    LoomnLoader(width: 70)
                    Text("Suche nach Updates").font(DS.font(16))
                }
            }
        case .available(let r):
            card {
                Text("Update verfügbar").dsLabel(DS.accent)
                Text("Version \(r.version) · Build \(r.build)").font(DS.font(22, .bold))
                Text("Installiert: \(updater.currentVersion) · Build \(updater.currentBuild)").dsLabel()
                if let notes = r.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes.prefix(8), id: \.self) { n in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Rectangle().fill(DS.accent).frame(width: 6, height: 2).offset(y: -4)
                                Text(n).font(DS.font(16)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack(spacing: DS.gap) {
                    DSButton("Später") { updater.later() }
                    DSButton("Aktualisieren", icon: "arrow.down.circle", fill: DS.accent) { updater.install() }
                }
            }
        case .installing:
            card {
                if updater.downloaded {
                    HStack(spacing: 12) {
                        LoomnLoader(width: 70)
                        Text("Wird installiert, \(updater.displayName) startet gleich neu").font(DS.font(16))
                    }
                } else {
                    let total = updater.expected
                    let frac = total > 0 ? min(Double(updater.received) / Double(total), 1) : 0
                    HStack {
                        Text("Update wird geladen").dsLabel(DS.accent)
                        Spacer()
                        Text(total > 0 ? "\(mb(updater.received)) / \(mb(total)) MB" : "\(mb(updater.received)) MB")
                            .font(DS.font(15, .semibold)).monospacedDigit().foregroundStyle(DS.dim)
                    }
                    // Schlichter Balken, füllt sich mit dem Download
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.line)
                            Capsule().fill(DS.accent).frame(width: max(8, g.size.width * frac))
                        }
                    }
                    .frame(height: 8)
                    .animation(.linear(duration: 0.2), value: frac)
                }
            }
        case .failed(let msg) where inline:
            // In den Einstellungen nur eine Statuszeile, ohne OK; verschwindet beim Verlassen des Reiters
            Text(msg).font(DS.font(18, .semibold)).foregroundStyle(DS.dim).fixedSize(horizontal: false, vertical: true)
        case .failed(let msg):
            card {
                Text(msg).font(DS.font(16)).fixedSize(horizontal: false, vertical: true)
                DSButton("OK") { updater.dismiss() }
            }
        }
    }

    private func mb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(DS.margin)
            .frame(width: inline ? 420 : 360, alignment: .leading)
            .foregroundStyle(DS.text)
            .background(DS.surfaceHi, in: DS.shape)
            .overlay(DS.shape.stroke(DS.line, lineWidth: 1))
            .shadow(color: .black.opacity(inline ? 0 : 0.5), radius: 20, y: 8)
            .padding(inline ? 0 : DS.margin)
            .padding(.top, inline ? 0 : 18)
    }
}
