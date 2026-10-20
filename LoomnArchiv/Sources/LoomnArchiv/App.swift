import AppKit
import SwiftUI

@main
struct LoomnArchivApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var updater: ToolUpdater

    init() {
        SelfTest.runIfRequested()
        ToolUpdater.runUpdateTestIfRequested(name: "LoomnArchiv", tagPrefix: "loomn-archiv-b")
        DS.registerFonts()
        // Scrollleisten nur beim Scrollen einblenden, über dem Inhalt: sonst wird alles schmaler,
        // sobald eine Liste länger wird (gilt nur für diese App, nicht systemweit)
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
        Screenshots.prepareIfRequested()
        _model = StateObject(wrappedValue: AppModel())
        _updater = StateObject(wrappedValue: ToolUpdater(name: "LoomnArchiv", tagPrefix: "loomn-archiv-b"))
    }

    var body: some Scene {
        Window("archivn", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.thumbs)
                .environmentObject(updater)
                // Solange die Einstellungen offen sind, steht das Ergebnis dort (Reiter Updates)
                .overlay(alignment: .topTrailing) { if !model.showSettings { UpdateBanner().environmentObject(updater) } }
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
                .onAppear {
                    if Screenshots.requested != nil {
                        Task { await Screenshots.capture(model: model, updater: updater) }
                    } else {
                        updater.start()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        // Fenster lässt sich nicht kleiner ziehen als der Inhalt braucht (sonst wird links abgeschnitten)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Videos ins Archiv …") {
                    let p = NSOpenPanel()
                    p.canChooseFiles = true
                    p.canChooseDirectories = true
                    p.allowsMultipleSelection = true
                    p.prompt = "Ins Archiv"
                    if p.runModal() == .OK { model.beginImport(p.urls) }
                }
                .keyboardShortcut("o")
                .disabled(!model.online)
                Button("Einstellungen …") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(before: .windowList) { CompanionMenuItem() }
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") {
                    model.settingsTab = 5
                    model.showSettings = true
                    updater.check(manual: true)
                }
            }
        }

        // Kompagnon: klein, schwebt über allen Apps, frei verschiebbar (Position merkt sich macOS),
        // bleibt offen, auch wenn das große Fenster zu ist
        Window("Kompagnon", id: "kompagnon") {
            CompanionView()
                .background(FloatingWindow())
                .environmentObject(model)
                .environmentObject(model.thumbs)
                .environmentObject(updater)
                // Eingeklappt darf das Fenster zum kleinen Viereck werden. Die Höhe zählt hier ohne den
                // unsichtbaren Titelstreifen, deshalb kleiner, sonst wird das Viereck hochkant
                .frame(minWidth: CompanionFold.size, minHeight: 16)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: CompanionFold.defaultSize.width, height: CompanionFold.defaultSize.height)
        .defaultPosition(.bottomTrailing)
    }
}

/// Klick aufs Symbol im Dock holt das große Fenster zurück, auch wenn nur der Kompagnon offen ist.
/// Ein Tool kann archivn per Link `archivn://andocken?prozess=…&fenster=…` bitten, den Kompagnon direkt
/// an seine Andockstelle zu legen (Ziel gedrückt halten). Mit `--nur-kompagnon` gestartet, bleibt das
/// große Fenster zu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var showMain: (() -> Void)?
    /// Vom großen Fenster gesetzt: Kompagnon-Fenster öffnen
    @MainActor static var openCompanion: (() -> Void)?
    @MainActor static var onlyCompanion = CommandLine.arguments.contains("--nur-kompagnon")
    /// Das große Fenster darf zu sehen sein. Nur LION selbst schaltet es ein (Dock-Symbol, Knopf im
    /// Kompagnon). Andocken, Lösen, Einklappen oder Aktivieren der App öffnen es nie.
    @MainActor static var mainWanted = !CommandLine.arguments.contains("--nur-kompagnon")
    /// Kurz nach einer Andock-Bewegung zählt auch ein Reopen von macOS nicht als Wunsch nach dem Fenster
    @MainActor static var quietUntil = Date.distantPast
    @MainActor static func quiet() { quietUntil = Date().addingTimeInterval(2) }
    private var watcher: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Taucht das große Fenster auf, ohne dass es gewollt ist: gleich wieder weg
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
                watcher.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated { Self.keepMainHidden(note.object as? NSWindow) }
                })
            }
            guard Self.onlyCompanion, let w = WindowFinder.main else { return }
            w.alphaValue = 0
            w.orderOut(nil)
            w.alphaValue = 1
        }
    }

    @MainActor static func keepMainHidden(_ w: NSWindow?) {
        guard !mainWanted, Screenshots.requested == nil || testingMain, let w, w === WindowFinder.main, w.isVisible else { return }
        w.orderOut(nil)
    }
    @MainActor static var testingMain = false

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.scheme == "archivn" && url.host == "andocken" {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let prozess = q.first(where: { $0.name == "prozess" })?.value.flatMap({ Int32($0) }),
                      let fenster = q.first(where: { $0.name == "fenster" })?.value.flatMap({ Int($0) }) else { continue }
                CompanionDock.shared.request(prozess: prozess, fenster: fenster)
                if WindowFinder.companion?.isVisible != true { Self.openCompanion?() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let quiet = MainActor.assumeIsolated { Date() < Self.quietUntil }
        if quiet { return false }
        MainActor.assumeIsolated {
            Self.mainWanted = true
            if let w = WindowFinder.main, w.isVisible, !w.isMiniaturized { return }
            if let show = Self.showMain {
                show()
            } else if let w = WindowFinder.main {
                w.deminiaturize(nil)
                w.makeKeyAndOrderFront(nil)
            }
        }
        // Ohne sichtbare Fenster öffnet SwiftUI das Hauptfenster selbst
        return !hasVisibleWindows
    }
}
