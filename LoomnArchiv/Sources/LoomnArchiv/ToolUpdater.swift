import AppKit
import CryptoKit
import Foundation

/// Updates für Loomn-Werkzeuge über GitHub Releases: kostenlos, ohne Konto, ohne Claude.
///
/// Der Build-Workflow veröffentlicht jede Version als Release mit dem Tag `<tagPrefix><build>`
/// und zwei Dateien: `<Name>.zip` und `version.json`. Zusätzlich liegt die neueste `version.json`
/// (mit direktem Link auf die ZIP) im festen Release `<tool>-aktuell`: ein einziger Abruf ohne
/// GitHub-API und ohne deren Abruflimit. Fehlt er, wird wie früher über die API gesucht. Aus welchem Repo, steht in der Info.plist
/// (`LoomnUpdateRepo`, "besitzer/repo"). Die App schaut beim Start und dann alle 30 Minuten nach,
/// zeigt Version und Änderungen an und installiert erst nach Bestätigung: lädt, prüft Prüfsumme
/// und Signatur, ersetzt sich selbst und startet neu.
@MainActor
final class ToolUpdater: ObservableObject {
    struct Release: Decodable, Equatable {
        var name: String
        var version: String
        var build: Int
        var date: String?
        var notes: [String]?
        var sha256: String
        var file: String?
        /// Direkter Link auf die ZIP (nur in der version.json des Release `…-aktuell`)
        var url: URL?
        var zipURL: URL?
        var zipSize: Int64?
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int64?
        }
        var tag_name: String
        var draft: Bool
        var assets: [Asset]
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(Release)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Download-Fortschritt während der Installation (Bytes); nil = noch unbekannt bzw. fertig geladen
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var downloaded = false
    @Published private(set) var lastCheck: Date?
    /// Version, die mit „Später“ weggeklickt wurde (bis zur nächsten neueren).
    private var skippedBuild: Int {
        get { UserDefaults.standard.integer(forKey: "update.skippedBuild") }
        set { UserDefaults.standard.set(newValue, forKey: "update.skippedBuild") }
    }

    let name: String
    let tagPrefix: String
    let repo: String?
    private var timer: Timer?

    var displayName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? name }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    init(name: String, tagPrefix: String) {
        self.name = name
        self.tagPrefix = tagPrefix
        let r = Bundle.main.object(forInfoDictionaryKey: "LoomnUpdateRepo") as? String
        repo = (r?.isEmpty ?? true) ? nil : r
    }

    func start() {
        guard timer == nil else { return }
        check(manual: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(manual: false) }
        }
    }

    /// `manual`: Ergebnis immer anzeigen und auch eine weggeklickte Version wieder anbieten.
    func check(manual: Bool) {
        switch phase {
        case .installing, .checking: return
        case .available: if !manual { return }
        default: break
        }
        lastCheck = Date()
        guard let repo else {
            if manual { phase = .failed("Für diese Version sind keine Updates eingerichtet") }
            return
        }
        if manual { phase = .checking }
        Task {
            do {
                guard let r = try await Self.latest(repo: repo, prefix: tagPrefix), r.name == name else {
                    if manual { phase = .failed("Keine Version zum Herunterladen gefunden") }
                    return
                }
                if r.build > currentBuild, manual || r.build > skippedBuild {
                    phase = .available(r)
                } else if manual {
                    phase = .failed("\(displayName) ist aktuell (\(currentVersion) · Build \(currentBuild))")
                } else if phase == .checking {
                    phase = .idle
                }
            } catch {
                // Ohne Internet still bleiben, nur auf Nachfrage melden
                if manual { phase = .failed("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)") } else if phase == .checking { phase = .idle }
            }
        }
    }

    /// Neueste Version mit passendem Tag. Mehrere Tools teilen sich das Repo, deshalb
    /// seitenweise suchen, bis Releases dieses Tools auftauchen (neueste zuerst).
    /// Eigene Sitzung mit Zeitlimits: hängt nichts, gibt es nach kurzer Zeit eine klare Meldung
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 300
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Schneller Weg: version.json direkt aus dem festen Release `<tool>-aktuell` (kein API-Abruf).
    nonisolated private static func channel(repo: String, prefix: String) async -> Release? {
        let tag = (prefix.hasSuffix("b") ? String(prefix.dropLast()) : prefix) + "aktuell"
        guard let u = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/version.json"),
              let res = try? await session.data(from: u),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              var r = try? JSONDecoder().decode(Release.self, from: res.0), let zip = r.url else { return nil }
        r.zipURL = zip
        return r
    }

    nonisolated private static func latest(repo: String, prefix: String) async throws -> Release? {
        if let r = await channel(repo: repo, prefix: prefix) { return r }
        var found: GitHubRelease?
        for page in 1...5 where found == nil {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100&page=\(page)") else { return nil }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            // Nur im automatischen Build gesetzt (gegen das Abruflimit), die App selbst braucht kein Konto
            if let t = ProcessInfo.processInfo.environment["LOOMN_UPDATE_TEST_TOKEN"], !t.isEmpty {
                req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            }
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub antwortet nicht (\((resp as? HTTPURLResponse)?.statusCode ?? 0))") }
            let all = try JSONDecoder().decode([GitHubRelease].self, from: data)
            found = all.filter { !$0.draft && $0.tag_name.hasPrefix(prefix) }
                .compactMap { r -> (Int, GitHubRelease)? in Int(r.tag_name.dropFirst(prefix.count)).map { ($0, r) } }
                .max { $0.0 < $1.0 }?.1
            if all.count < 100 { break }
        }
        guard let rel = found, let info = rel.assets.first(where: { $0.name == "version.json" }) else { return nil }
        let (vdata, _) = try await session.data(from: info.browser_download_url)
        var r = try JSONDecoder().decode(Release.self, from: vdata)
        let zipName = r.file ?? "\(r.name).zip"
        r.zipURL = rel.assets.first { $0.name == zipName }?.browser_download_url
        r.zipSize = rel.assets.first { $0.name == zipName }?.size
        return r.zipURL == nil ? nil : r
    }

    func later() {
        if case .available(let r) = phase { skippedBuild = r.build }
        phase = .idle
    }

    func dismiss() { phase = .idle }

    func install() {
        guard case .available(let r) = phase, let zipURL = r.zipURL else { return }
        let target = Bundle.main.bundleURL
        // Direkt aus „Downloads“ gestartet, läuft die App von einer schreibgeschützten Kopie des Systems
        if target.path.contains("/AppTranslocation/") {
            phase = .failed("Zieh die App einmal in den Ordner Programme und starte sie von dort, dann klappt das Aktualisieren.")
            return
        }
        // Ohne Schreibrecht im App-Ordner würde der Austausch nach dem Beenden still scheitern
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            phase = .failed("Im Ordner der App fehlt das Schreibrecht. Lege die App z. B. in deinen Benutzerordner und versuch es erneut.")
            return
        }
        phase = .installing
        received = 0
        expected = r.zipSize ?? 0
        downloaded = false
        let bundleID = Bundle.main.bundleIdentifier
        let watch = DownloadWatch { done, total in
            Task { @MainActor in
                self.received = done
                if total > 0 { self.expected = total }
            }
        }
        Task.detached {
            do {
                let (tmpZip, _) = try await Self.session.download(from: zipURL, delegate: watch)
                await MainActor.run { self.downloaded = true }
                let newApp = try Self.prepare(zip: tmpZip, sha256: r.sha256, expectedBundleID: bundleID)
                try await MainActor.run { try Self.replaceAndRelaunch(current: target, with: newApp) }
            } catch {
                await MainActor.run { self.phase = .failed("Update fehlgeschlagen: \(error.localizedDescription)") }
            }
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Prüfen und in einen temporären Ordner auspacken.
    nonisolated private static func prepare(zip: URL, sha256: String, expectedBundleID: String?) throws -> URL {
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw Failure("Update-Datei ist beschädigt oder unvollständig") }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw Failure("Keine App im Update") }
        guard Bundle(url: app)?.bundleIdentifier == expectedBundleID else { throw Failure("Update gehört zu einer anderen App") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], failure: "Signatur des Updates ungültig")
        // Kein Quarantäne-Hinweis beim Neustart
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Kleines Hilfsskript: wartet, bis diese App beendet ist, tauscht sie aus und startet neu.
    /// Die alte Version landet im Papierkorb (falls doch etwas schiefgeht).
    private static func replaceAndRelaunch(current: URL, with newApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.path ?? "/tmp"
        let backup = "\(trash)/\(current.deletingPathExtension().lastPathComponent) alt \(Int(Date().timeIntervalSince1970)).app"
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        mv "\(current.path)" "\(backup)" && mv "\(newApp.path)" "\(current.path)" || mv "\(backup)" "\(current.path)"
        open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        // Falls das Beenden irgendwo hängen bleibt: nach kurzer Zeit hart beenden, damit der Tausch läuft.
        // Läuft bewusst nicht auf dem Haupt-Thread, der könnte ja gerade festhängen.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String], failure: String? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Failure(failure ?? "\(URL(fileURLWithPath: tool).lastPathComponent) fehlgeschlagen") }
        return p.terminationStatus
    }

    // MARK: - Update-Test für den automatischen Build

    /// `<App> --updatetest <build>`: kommt Build <build> (oder neuer) über GitHub an und ließe er sich
    /// installieren (Prüfsumme, Signatur, richtige App)? Ersetzt nichts. Ganz am Anfang von init() aufrufen.
    nonisolated static func runUpdateTestIfRequested(name: String, tagPrefix: String) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--updatetest") else { return }
        let want = i + 1 < args.count ? Int(args[i + 1]) ?? 0 : 0
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                guard let repo = Bundle.main.object(forInfoDictionaryKey: "LoomnUpdateRepo") as? String, !repo.isEmpty else {
                    throw Failure("Kein Update-Repo eingetragen")
                }
                print(await channel(repo: repo, prefix: tagPrefix) != nil ? "Schneller Weg (…-aktuell) erreichbar" : "Schneller Weg fehlt, Suche über die API")
                guard let r = try await latest(repo: repo, prefix: tagPrefix), r.name == name, let zip = r.zipURL else {
                    throw Failure("Keine Version in \(repo) gefunden")
                }
                let (tmp, _) = try await session.download(from: zip)
                let app = try prepare(zip: tmp, sha256: r.sha256, expectedBundleID: Bundle.main.bundleIdentifier)
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                print("Update gefunden: Version \(r.version) Build \(r.build), Prüfsumme und Signatur ok")
                if r.build < want { print("FEHLER: erwartet Build \(want)"); code = 1 } else { print("UPDATE-TEST OK") }
            } catch {
                print("FEHLER: \(error.localizedDescription)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        exit(code)
    }
}

/// Meldet, wie viel vom Update schon geladen ist.
final class DownloadWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private var observation: NSKeyValueObservation?
    private var last: Int64 = -1

    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.completedUnitCount) { [weak self] p, _ in
            guard let self else { return }
            let done = p.completedUnitCount
            // Nicht jede Kleinigkeit melden: etwa alle 256 KB
            guard done - self.last >= 256 * 1024 || done == p.totalUnitCount else { return }
            self.last = done
            self.report(done, p.totalUnitCount)
        }
    }
}
