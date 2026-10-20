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
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var showMain: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
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
