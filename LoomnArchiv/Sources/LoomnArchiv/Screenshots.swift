import AppKit
import SwiftUI

/// `LoomnArchiv --screenshots <ordner>`: legt eine Beispiel-Mediathek an und speichert Bilder der
/// wichtigsten Ansichten (für den automatischen Build, zur Kontrolle der Oberfläche).
enum Screenshots {
    static var requested: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots") else { return nil }
        return URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "loomn-archiv-shots")
    }

    /// Vor dem Start der Oberfläche: Beispiel-Mediathek anlegen und als gemerkte Mediathek eintragen.
    static func prepareIfRequested() {
        guard let dir = requested else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await prepare(dir) } catch { print("FEHLER Vorbereitung: \(error)"); exit(1) }
            sem.signal()
        }
        sem.wait()
    }

    static func prepare(_ dir: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let src = dir.appendingPathComponent("Quelle", isDirectory: true)
        let ssd = dir.appendingPathComponent("SSD", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: ssd, withIntermediateDirectories: true)
        let lib = try Library.create(in: ssd)
        var cat = await lib.currentCatalog()
        let s1 = cat.songNamed("Nachtfahrt")
        let s2 = cat.songNamed("Goldene Stunde")
        let s3 = cat.songNamed("Atem")
        // Eigene Moods, wie sie jemand selbst anlegen würde
        for n in ["warm", "verträumt", "melancholisch"] { cat.addMood(n) }
        try await lib.setCatalog(cat)
        // Nachtfahrt mit zwei Audio-Versionen, die anderen Songs noch ohne
        for (i, secs) in [196.0, 204.0].enumerated() {
            let wav = src.appendingPathComponent("Nachtfahrt_Mix\(i + 1).wav")
            try silentWAV(seconds: 2, seed: i).write(to: wav)
            _ = try await lib.addSongAudio(to: s1.id, title: "", from: wav, duration: secs)
        }
        cat = await lib.currentCatalog()
        func f(_ n: String) -> String { cat.formats.first { $0.name == n }!.id }
        func m(_ n: String) -> String { cat.moods.first { $0.name == n }!.id }
        let plan: [(String, Attrs, String)] = [
            ("IMG_4101.mov", Attrs(kindID: Kind.raw, songIDs: [s1.id], formatID: f("Zoom-out"), moodIDs: [m("ruhig"), m("dunkel")], description: "Straße bei Nacht", tags: ["Stadt"]), "2026-09-02T22:10:00+02:00"),
            ("IMG_4102.mov", Attrs(kindID: Kind.raw, songIDs: [s1.id], formatID: f("Zoom-out"), moodIDs: [m("ruhig")], tags: ["Stadt"]), "2026-09-02T22:14:00+02:00"),
            ("nachtfahrt_cut.mov", Attrs(kindID: Kind.cut, songIDs: [s1.id], formatID: f("Splitscreen"), moodIDs: [m("energetisch")]), "2026-09-03T11:00:00+02:00"),
            ("nachtfahrt_final.mov", Attrs(kindID: Kind.final, songIDs: [s1.id], formatID: f("Stutter"), moodIDs: [m("energetisch"), m("dunkel")]), "2026-09-04T18:30:00+02:00"),
            ("gold_01.mov", Attrs(kindID: Kind.raw, songIDs: [s2.id], formatID: f("Slow-Mo"), moodIDs: [m("warm"), m("verträumt")], description: "Abendsonne am See"), "2026-08-15T19:45:00+02:00"),
            ("gold_edit.mov", Attrs(kindID: Kind.edit, songIDs: [s2.id], formatID: f("Slow-Mo"), moodIDs: [m("warm")]), "2026-08-16T10:00:00+02:00"),
            ("atem_perf.mov", Attrs(kindID: Kind.raw, songIDs: [s3.id], formatID: f("Zoom-out"), moodIDs: [m("melancholisch")]), "2026-07-01T14:00:00+02:00"),
            ("wald_slowmo.mov", Attrs(kindID: Kind.raw, songIDs: [s3.id], formatID: f("Slow-Mo"), moodIDs: [m("ruhig")], tags: ["Natur"]), "2026-06-20T09:30:00+02:00"),
        ]
        for (i, p) in plan.enumerated() {
            let url = src.appendingPathComponent(p.0)
            try await SelfTest.makeVideo(url, hue: Double(i) / Double(plan.count), creation: p.2, loomnTake: false)
            if case .imported(let r) = try await Importer.importFile(url, sha: nil, attrs: p.1, into: lib) {
                try await Previews.generate(video: lib.paths.url(r.relPath), id: r.id, into: [lib.paths.previews])
            }
        }
        // Zwei neue Videos für das Import-Fenster
        try await SelfTest.makeVideo(src.appendingPathComponent("neu/IMG_5001.mov"), hue: 0.15, creation: nil, loomnTake: false)
        try await SelfTest.makeVideo(src.appendingPathComponent("neu/reel_export.mov"), hue: 0.55, creation: nil, loomnTake: false)
        let man = await lib.currentManifest()
        let d = UserDefaults.standard
        d.set(lib.root.path, forKey: "library.path")
        d.set(man.id, forKey: "library.id")
        d.set("SSD", forKey: "library.volume")
        try? fm.removeItem(at: Previews.cacheRoot(libraryID: man.id))
    }

    /// Kurze WAV-Datei (leises Rauschen), damit Songs im Beispiel Audio haben.
    static func silentWAV(seconds: Int, seed: Int) -> Data {
        let rate = 44_100, n = rate * seconds
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 2)
        var g = SystemRandomNumberGenerator()
        for i in 0..<n {
            // Rauschen mit wechselnder Lautstärke, damit die Wellenform nach Musik aussieht
            let t = Double(i) / Double(rate)
            let amp = 600 + 9000 * abs(sin(t * 2.1 + Double(seed))) * (0.5 + 0.5 * abs(sin(t * 11.0)))
            u16(Int(UInt16(truncatingIfNeeded: Int(Double(Int.random(in: -1000...1000, using: &g)) / 1000 * amp))))
        }
        return d
    }

    /// Nach dem Start: Ansichten nacheinander fotografieren, dann beenden.
    @MainActor
    static func capture(model: AppModel, updater: ToolUpdater) async {
        guard let dir = requested else { return }
        let out = dir.appendingPathComponent("Bilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for _ in 0..<100 where !model.online { try? await Task.sleep(nanoseconds: 100_000_000) }
        print("Mediathek: \(model.state), \(model.records.count) Videos")

        /// Prüfung gegen die graue macOS-Titelleiste (Rückfall in Build 123 und 129): Im echten Fenster muss
        /// der Inhalt bis ganz oben reichen. Durchsichtige oberste Zeilen heißen: Der Titelstreifen ist leer
        /// und macOS zeigt dort seine graue Leiste.
        var titleBarFailed = false
        func checkTitleBar(_ name: String, _ rep: NSBitmapImageRep) {
            var bad: [String] = []
            let scale = rep.pixelsHigh / max(Int(rep.size.height), 1)
            for y in [1, 6, 14, 24] {
                for fx in [0.5, 0.75, 0.9] {
                    let x = Int(Double(rep.pixelsWide) * fx)
                    guard let c = rep.colorAt(x: x, y: y * scale) else { continue }
                    if c.alphaComponent < 0.9 { bad.append("x\(x) y\(y)") }
                }
            }
            if bad.isEmpty { print("Titelleiste OK: \(name)") } else {
                titleBarFailed = true
                print("FEHLER Titelleiste: \(name) oben nicht gefüllt (\(bad.joined(separator: ", ")))")
            }
        }

        /// `realWindow`: Fenster wie in der App (Titelleiste unsichtbar, Inhalt darunter), damit
        /// Versätze durch den Titelstreifen auch im Bild auffallen
        func shot<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 1440, height: 900), using other: AppModel? = nil, realWindow: Bool = false) async {
            let m = other ?? model
            let root = view
                .environmentObject(m)
                .environmentObject(m.thumbs)
                .environmentObject(updater)
                // Im echten Fenster bestimmt das Fenster die Größe, nicht der Inhalt (wie in der App)
                .frame(width: realWindow ? nil : size.width, height: realWindow ? nil : size.height)
                .frame(minWidth: realWindow ? CompanionFold.size : nil, minHeight: realWindow ? 16 : nil)
                // Im echten Fenster ohne eigenen Hintergrund: was die Ansicht oben nicht selbst füllt, bleibt
                // durchsichtig und fällt bei der Titelleisten-Prüfung auf
                .background(realWindow ? Color.clear : DS.bg)
                .foregroundStyle(DS.text)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: realWindow ? [.titled, .fullSizeContentView] : [.titled], backing: .buffered, defer: false)
            if realWindow {
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.setContentSize(size)
            }
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            win.orderFront(nil)
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                host.layoutSubtreeIfNeeded()
            }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
                print("Bild: \(name)")
                if realWindow { checkTitleBar(name, rep) }
            }
            win.orderOut(nil)
        }

        let nacht = model.catalog.songs.first(where: { $0.title == "Nachtfahrt" })?.id ?? ""
        model.page = .song(nacht)
        await shot("1-oberflaeche", RootView())
        model.selection = Set(model.records.filter { $0.kind.id == Kind.cut }.map(\.id))
        await shot("2-song-nachtfahrt", RootView())
        model.selection = []
        model.page = .all
        model.selection = Set(model.records.filter { $0.kind.id == Kind.final }.map(\.id))
        await shot("3-bibliothek-auswahl", RootView())
        model.selection = []
        model.page = .song(nacht)
        var f = LibraryFilter()
        f.kindIDs = [Kind.raw, Kind.final]
        f.moodIDs = Set(model.catalog.moods.filter { $0.name == "ruhig" }.map(\.id))
        model.filter = f
        await shot("4-suche-nachtfahrt-raw-ruhig", RootView())
        model.filter = LibraryFilter()
        if let gold = model.catalog.songs.first(where: { $0.title == "Goldene Stunde" }) { model.page = .song(gold.id) }
        await shot("2b-song-ohne-audio", RootView())
        await shot("8-neuer-song", NewSongSheet(initialTitle: "Sommerregen"), size: CGSize(width: 540, height: 420))
        model.page = .all
        await shot("9-zeitraum", MoreFilters().padding(DS.margin), size: CGSize(width: 460, height: 760))
        await shot("9-kompagnon", CompanionView(), size: CGSize(width: 360, height: 640))
        await shot("9c-kompagnon-schmal", CompanionView(), size: CGSize(width: CompanionFold.minSize.width, height: 500))
        await shot("9b-kompagnon-eingeklappt", CompanionBubble {}, size: CGSize(width: CompanionFold.size, height: CompanionFold.size), realWindow: true)
        await shot("9d-kompagnon-fenster", CompanionView(), size: CompanionFold.defaultSize, realWindow: true)
        await shot("5-einstellungen", SettingsView(), size: CGSize(width: 1080, height: 700))
        await shot("5b-formate", SettingsView(tab: 1), size: CGSize(width: 1080, height: 700))

        model.beginImport([dir.appendingPathComponent("Quelle/neu")])
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await shot("6-import", ImportSheet(), size: CGSize(width: 1020, height: 760))
        model.importDraft?.selection = []
        await shot("6b-import-nur-song", ImportSheet(), size: CGSize(width: 1020, height: 760))
        model.cancelImport()
        // Erster Start ohne gemerktes Archiv: gleiche Oberfläche, kein eigener Startbildschirm
        for k in ["library.path", "library.id", "library.volume"] { UserDefaults.standard.removeObject(forKey: k) }
        let fresh = AppModel()
        await shot("7-erster-start", RootView(), using: fresh)
        print(titleBarFailed ? "FEHLER Titelleiste: siehe oben" : "Titelleiste OK")
        print("BILDER OK")
        exit(0)
    }
}
