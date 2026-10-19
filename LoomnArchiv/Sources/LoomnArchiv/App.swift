import SwiftUI

@main
struct LoomnArchivApp: App {
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
        Window("Loomn Archiv", id: "main") {
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
                .frame(minWidth: 320, minHeight: 440)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 360, height: 640)
        .defaultPosition(.bottomTrailing)
    }
}
