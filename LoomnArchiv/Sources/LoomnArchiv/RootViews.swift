import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: ToolUpdater
    @State private var dropTarget = false

    var body: some View {
        // Immer die eine Oberfläche. Kein eigener Startbildschirm: Der Speicherort wird beim
        // ersten Reinziehen gewählt, Fehler und Laden stehen als Leiste über dem Drop-Feld.
        main
        .windowGripMargin()
        .overlay(alignment: .topTrailing) {
            if let note = model.inboxNote {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 14, weight: .bold))
                    Text(note).font(DS.controlFont)
                }
                .padding(.horizontal, 14)
                .frame(height: DS.control)
                .foregroundStyle(DS.bg)
                .background(DS.accent, in: DS.shape)
                .padding(.top, 72)
                .padding(.trailing, DS.margin)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.inboxNote)
        .background(DS.bg)
        .foregroundStyle(DS.text)
        .alert("Loomn Archiv", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .sheet(isPresented: Binding(get: { model.importDraft != nil }, set: { if !$0 { model.cancelImport() } })) {
            ImportSheet().environmentObject(model)
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            TopBar()
            Rectangle().fill(DS.line).frame(height: 1)
            if case .offline(let vol) = model.state {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.xmark").font(.system(size: 15, weight: .bold))
                    Text("SSD „\(vol)“ anschließen").font(DS.font(18, .bold))
                    Spacer()
                    DSButton("Erneut suchen", icon: "arrow.clockwise") { model.reconnect() }.frame(width: 190)
                }
                .foregroundStyle(DS.bg)
                .padding(.horizontal, DS.margin)
                .padding(.vertical, 8)
                .background(DS.amber)
            }
            if case .failed(let msg) = model.state {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15, weight: .bold))
                    Text(msg).font(DS.font(16)).lineLimit(2)
                    Spacer()
                    if model.hasRemembered {
                        DSButton("Erneut versuchen", icon: "arrow.clockwise") { model.reconnect() }.frame(width: 200)
                    }
                    DSButton("Anderen Ort wählen", icon: "folder") { model.chooseStorage() }.frame(width: 220)
                }
                .padding(.horizontal, DS.margin)
                .padding(.vertical, 8)
                .background(DS.error.opacity(0.25))
            }
            if case .opening(let msg) = model.state {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(msg).font(DS.font(16)).foregroundStyle(DS.dim)
                    Spacer()
                }
                .padding(.horizontal, DS.margin)
                .padding(.vertical, 8)
            }
            HStack(spacing: 0) {
                SongSidebar().frame(width: 260)
                Rectangle().fill(DS.line).frame(width: 1)
                BrowserView()
            }
            JobsBar()
        }
        .overlay {
            if dropTarget {
                DS.shape.stroke(DS.accent, lineWidth: DS.stroke).padding(DS.gap).allowsHitTesting(false)
            }
        }
        .overlay {
            if let busy = model.busy {
                ZStack {
                    Color.black.opacity(0.6)
                    VStack(spacing: 14) {
                        LoomnLoader(width: 140)
                        Text(busy).font(DS.font(18)).lineLimit(2).multilineTextAlignment(.center)
                        if let p = model.busyProgress { DSProgress(value: p).frame(width: 360) }
                    }
                    .padding(30)
                    .background(DS.surfaceHi, in: DS.shape)
                }
            }
        }
        .sheet(isPresented: $model.showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Einstellungen").font(DS.font(30, .bold))
                    Spacer()
                    DSButton("Fertig", fill: DS.accent) { model.showSettings = false }
                        .frame(width: 140)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(DS.margin)
                Rectangle().fill(DS.line).frame(height: 1)
                SettingsView()
            }
            .frame(width: 1080, height: 760)
            .background(DS.bg)
            .foregroundStyle(DS.text)
            .preferredColorScheme(.dark)
            .environmentObject(model)
            .environmentObject(updater)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            Self.loadURLs(providers) { model.beginImport($0) }
            return true
        }
    }

    static func loadURLs(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
    }
}

// MARK: - Kopfzeile

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: ToolUpdater

    var body: some View {
        HStack(spacing: DS.margin) {
            Text("LOOMN ARCHIV").font(DS.font(26, .bold)).tracking(2)
                .allowsHitTesting(false) // Klicks gehen an die Leiste (verschieben, Doppelklick zoomt)
                .padding(.leading, 58) // Platz für die Fensterknöpfe
            Spacer()
            SSDStatus()
            CompanionButton()
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 17, weight: .semibold))
                    .frame(width: DS.control, height: DS.control).background(DS.surface, in: DS.shape).contentShape(DS.shape)
            }
            .buttonStyle(DSPress())
            .help("Einstellungen: Mediathek, Formate, Moods, Songs, Updates (⌘,)")
        }
        .padding(.horizontal, DS.margin)
        .padding(.top, 10)
        .padding(.bottom, 10)
        // Freie Stellen der Leiste: ziehen verschiebt, Doppelklick zoomt
        .background(WindowDragArea())
        .background(DS.surface.opacity(0.4))
    }

}

/// Oben rechts: SSD, freier Platz, Warnung vor „voll“.
struct SSDStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.hasLibrary {
            Button { model.chooseStorage() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive").font(.system(size: 13, weight: .semibold))
                    Text("Speicherort wählen").font(DS.controlFont)
                }
                .padding(.horizontal, 12)
                .frame(height: DS.control)
                .background(DS.surface, in: DS.shape)
                .contentShape(DS.shape)
            }
            .buttonStyle(DSPress())
            .help("Wo das Archiv liegt, am besten auf der SSD. Wird sonst beim ersten Reinziehen gefragt.")
        } else {
            status
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            Image(systemName: model.online ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.online ? color : DS.amber)
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.online ? (FileOps.volumeName(model.libraryRoot ?? URL(fileURLWithPath: "/")) ?? "SSD") : "SSD „\(model.rememberedVolume)“ fehlt")
                    .font(DS.font(16, .bold)).lineLimit(1)
                if model.online, let free = model.freeSpace {
                    HStack(spacing: 6) {
                        Text("\(free.bytes) frei").dsLabel(color == DS.dim ? DS.dim : color)
                        if let total = model.totalSpace, total > 0 {
                            DSProgressBar(value: 1 - Double(free) / Double(total), tint: color == DS.dim ? DS.text : color)
                                .frame(width: 70)
                        }
                    }
                }
            }
        }
        .help(help)
    }

    private var color: Color {
        if let root = model.libraryRoot, FileOps.isInternal(root) { return DS.amber }
        switch model.spaceLevel {
        case .ok: return DS.dim
        case .low: return DS.amber
        case .critical: return DS.error
        }
    }

    private var help: String {
        if let root = model.libraryRoot, FileOps.isInternal(root) {
            return "Das Archiv liegt auf dem Mac, nicht auf einer SSD. Einstellungen › Mediathek › Umziehen bringt es auf die SSD."
        }
        switch model.spaceLevel {
        case .ok: return model.libraryRoot?.path ?? ""
        case .low: return "Die SSD wird voll. Bald Platz schaffen oder eine größere SSD nehmen (Einstellungen › Umziehen)."
        case .critical: return "Die SSD ist fast voll. Importe können bald nicht mehr kopiert werden."
        }
    }
}

struct DSProgressBar: View {
    var value: Double
    var tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line)
                Capsule().fill(tint).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Laufende Importe (unten)

struct JobsBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let jobs = model.jobs
        if !jobs.list.isEmpty {
            VStack(spacing: 0) {
                Rectangle().fill(DS.line).frame(height: 1)
                HStack(spacing: 14) {
                    if jobs.active > 0 {
                        LoomnLoader(width: 54)
                        let current = jobs.list.first { if case .running = $0.status { return true }; return false }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ins Archiv: \(jobs.done) von \(jobs.list.count - jobs.duplicates - jobs.failed.count) fertig").font(DS.font(17, .bold))
                            if let current, case .running(let step) = current.status {
                                Text("\(current.name) · \(step)").dsLabel()
                            }
                        }
                    } else {
                        Image(systemName: jobs.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 20)).foregroundStyle(jobs.failed.isEmpty ? DS.accent : DS.error)
                        Text(summary(jobs)).font(DS.font(17, .bold))
                    }
                    if !jobs.failed.isEmpty {
                        Menu("\(jobs.failed.count) Fehler") {
                            ForEach(jobs.failed) { j in
                                if case .failed(let msg) = j.status { Text("\(j.name): \(msg)") }
                            }
                        }
                        .fixedSize()
                    }
                    Spacer()
                    if jobs.active == 0, !jobs.failed.isEmpty {
                        DSButton("OK") { model.clearFinishedJobs() }.frame(width: 80)
                    }
                }
                .padding(.horizontal, DS.margin)
                .padding(.vertical, 8)
                .background(DS.surface)
            }
        }
    }

    private func summary(_ j: ImportJobs) -> String {
        var parts = ["\(j.done) Videos im Archiv"]
        if j.duplicates > 0 { parts.append("\(j.duplicates) schon da") }
        return parts.joined(separator: " · ") + ". Kopien geprüft."
    }
}
