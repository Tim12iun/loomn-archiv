import AppKit

/// Loomn-Andocken · Version 1
///
/// Diese Datei ist in archivn und in jedem Tool mit Andockstelle WORTGLEICH. Nur über eine neue Fassung
/// der Übergabe „Andocken“ ändern, nie in einem einzelnen Tool. Regeln: Mitteilungen und Felder nie
/// umbenennen oder entfernen, nur neue optionale Felder ergänzen; unbekannte Felder werden ignoriert.
///
/// Ablauf: Ein Tool meldet über systemweite Mitteilungen, wo seine Andockstelle gerade auf dem Bildschirm
/// liegt (`platz`). Zieht man den eingeklappten Kompagnon auf das orange `ziel`, legt archivn ihn genau auf
/// `bereich` und meldet seinen Zustand zurück (`zustand`). Alles geht als JSON-Text im `object` der
/// Mitteilung, nie als `userInfo`: so klappt es auch mit Sandbox. Keine Systemfreigabe, kein iCloud.
/// Maße in Punkten, Bildschirmkoordinaten von AppKit (Ursprung unten links, wie `NSWindow.frame`).
enum LoomnAndocken {
    static let andocken = 1
    static let archivBundleID = "de.loomn.archiv"

    /// Werte für `Zustand.zustand`
    static let schwebt = "schwebt", angedockt = "angedockt", geloest = "geloest"

    enum Mitteilung: String {
        /// Tool → archivn: so liegt meine Andockstelle gerade
        case platz = "de.loomn.andocken.platz"
        /// Tool → archivn: dieses Fenster gibt es nicht mehr
        case weg = "de.loomn.andocken.weg"
        /// archivn → Tools: bitte alle `platz` neu senden
        case frage = "de.loomn.andocken.frage"
        /// archivn → Tool: schwebt drüber, angedockt, gelöst
        case zustand = "de.loomn.andocken.zustand"
        var name: Notification.Name { Notification.Name(rawValue) }
    }

    struct Rechteck: Codable, Equatable {
        var x: Double, y: Double, breite: Double, hoehe: Double
        init(_ r: NSRect) { x = r.minX; y = r.minY; breite = r.width; hoehe = r.height }
        var rect: NSRect { NSRect(x: x, y: y, width: breite, height: hoehe) }
    }

    struct Platz: Codable, Equatable {
        var andocken = LoomnAndocken.andocken
        /// Kurzname des Tools, z. B. "moshn"
        var tool: String
        var prozess: Int32
        /// `windowNumber` des Tool-Fensters
        var fenster: Int
        /// Fläche, die der Kompagnon belegen darf
        var bereich: Rechteck
        /// Das orange Viereck, auf das man den Kompagnon fallen lässt
        var ziel: Rechteck
        /// Andockstelle gerade zu sehen (Fenster offen, nicht minimiert, Ansicht passt)
        var sichtbar: Bool
        /// Das Tool ist die vordere App
        var vorn: Bool
        /// Eckenradius von `bereich`
        var ecken: Double
        /// Fenster wird gerade verschoben oder in der Größe gezogen
        var bewegt: Bool?
    }

    struct Weg: Codable {
        var andocken = LoomnAndocken.andocken
        var tool: String
        var prozess: Int32
        var fenster: Int
    }

    struct Frage: Codable {
        var andocken = LoomnAndocken.andocken
    }

    struct Zustand: Codable {
        var andocken = LoomnAndocken.andocken
        var prozess: Int32
        var fenster: Int
        /// `schwebt`, `angedockt` oder `geloest`
        var zustand: String
    }

    // MARK: - Senden und Empfangen

    static func sende<T: Encodable>(_ m: Mitteilung, _ wert: T) {
        guard let daten = try? JSONEncoder().encode(wert), let text = String(data: daten, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(m.name, object: text, userInfo: nil, deliverImmediately: true)
    }

    /// Ruft `tu` auf dem Hauptthread auf. Das Ergebnis beim Aufräumen an `DistributedNotificationCenter.removeObserver` geben.
    @discardableResult
    static func empfange<T: Decodable>(_ m: Mitteilung, _ typ: T.Type, _ tu: @escaping @MainActor (T) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: m.name, object: nil, queue: .main) { n in
            guard let text = n.object as? String, let daten = text.data(using: .utf8),
                  let wert = try? JSONDecoder().decode(T.self, from: daten) else { return }
            MainActor.assumeIsolated { tu(wert) }
        }
    }

    // MARK: - Tool-Seite

    /// Eine Andockstelle in einem Tool-Fenster. Das Tool sagt nur, wo `bereich` und `ziel` im Fenster liegen
    /// (Fensterkoordinaten, wie `NSView.convert(_:to: nil)`) und ob sie zu sehen sind. Den Rest erledigt diese
    /// Klasse: Bildschirmlage, Verschieben, Größe ziehen, Minimieren, vorn und hinten, Schließen, Beenden,
    /// Antwort auf `frage`, und ob archivn überhaupt läuft.
    @MainActor
    final class Andockstelle {
        let tool: String
        private(set) weak var fenster: NSWindow?
        var ecken: Double = 8

        /// archivn läuft: nur dann zeigt das Tool sein oranges Ziel
        private(set) var archivLaeuft = false { didSet { if archivLaeuft != oldValue { beiArchiv?(archivLaeuft) } } }
        /// Was archivn über dieses Fenster gemeldet hat: `schwebt`, `angedockt` oder `geloest`
        private(set) var zustand = LoomnAndocken.geloest { didSet { if zustand != oldValue { beiZustand?(zustand) } } }
        var beiArchiv: ((Bool) -> Void)?
        var beiZustand: ((String) -> Void)?

        private var bereichImFenster = NSRect.zero
        private var zielImFenster = NSRect.zero
        private var sichtbar = false
        private var bewegt = false
        private var zuletzt: Platz?
        private var beobachter: [(NotificationCenter, NSObjectProtocol)] = []
        private var takt: Timer?
        private var beendet = false

        init(tool: String, fenster: NSWindow) {
            self.tool = tool
            self.fenster = fenster
            starte()
        }

        /// Lage im Fenster (Fensterkoordinaten) und Sichtbarkeit; bei jeder Änderung aufrufen.
        func aktualisiere(bereich: NSRect, ziel: NSRect, sichtbar: Bool) {
            bereichImFenster = bereich
            zielImFenster = ziel
            self.sichtbar = sichtbar
            sende()
        }

        /// Fenster geht weg oder die Andockstelle wird nicht mehr gebraucht.
        func beende() {
            guard !beendet else { return }
            beendet = true
            takt?.invalidate()
            if let f = fenster {
                LoomnAndocken.sende(.weg, Weg(tool: tool, prozess: getpid(), fenster: f.windowNumber))
            }
            for (c, b) in beobachter { c.removeObserver(b) }
            beobachter = []
        }

        private func starte() {
            let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
            let dnc = DistributedNotificationCenter.default()
            let f = fenster

            auf(nc, NSWindow.didMoveNotification, f) { $0.sende() }
            auf(nc, NSWindow.didResizeNotification, f) { $0.sende() }
            auf(nc, NSWindow.willMoveNotification, f) { $0.bewegungStart() }
            auf(nc, NSWindow.willStartLiveResizeNotification, f) { $0.bewegt = true; $0.sende() }
            auf(nc, NSWindow.didEndLiveResizeNotification, f) { $0.bewegt = false; $0.sende() }
            auf(nc, NSWindow.didMiniaturizeNotification, f) { $0.sende() }
            auf(nc, NSWindow.didDeminiaturizeNotification, f) { $0.sende() }
            auf(nc, NSWindow.didChangeOcclusionStateNotification, f) { $0.sende() }
            auf(nc, NSWindow.didBecomeMainNotification, f) { $0.sende(immer: true) }
            auf(nc, NSWindow.didChangeScreenNotification, f) { $0.sende() }
            auf(nc, NSWindow.willCloseNotification, f) { $0.beende() }
            auf(nc, NSApplication.didBecomeActiveNotification, nil) { $0.sende(immer: true) }
            auf(nc, NSApplication.didResignActiveNotification, nil) { $0.sende() }
            auf(nc, NSApplication.willTerminateNotification, nil) { $0.beende() }
            auf(ws, NSWorkspace.didLaunchApplicationNotification, nil) { $0.pruefeArchiv() }
            auf(ws, NSWorkspace.didTerminateApplicationNotification, nil) { $0.pruefeArchiv() }

            let eigen = getpid()
            let frage = LoomnAndocken.empfange(.frage, Frage.self) { [weak self] _ in
                self?.pruefeArchiv(); self?.sende(immer: true)
            }
            let zustand = LoomnAndocken.empfange(.zustand, Zustand.self) { [weak self] z in
                guard let self, z.prozess == eigen, z.fenster == self.fenster?.windowNumber else { return }
                self.zustand = z.zustand
            }
            beobachter.append((dnc, frage))
            beobachter.append((dnc, zustand))
            pruefeArchiv()
        }

        private func auf(_ c: NotificationCenter, _ n: Notification.Name, _ objekt: AnyObject?,
                         _ tu: @escaping @MainActor (Andockstelle) -> Void) {
            let b = c.addObserver(forName: n, object: objekt, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { tu(self) } }
            }
            beobachter.append((c, b))
        }

        private func pruefeArchiv() {
            archivLaeuft = !NSRunningApplication.runningApplications(withBundleIdentifier: LoomnAndocken.archivBundleID).isEmpty
            if !archivLaeuft { zustand = LoomnAndocken.geloest }
        }

        /// Beim Ziehen am Fenster kommt `didMove` nicht immer laufend: solange die Maus gedrückt ist,
        /// wird die Lage mit jedem Bild gemeldet.
        private func bewegungStart() {
            bewegt = true
            sende()
            takt?.invalidate()
            takt = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        t.invalidate(); self.takt = nil; self.bewegt = false
                    }
                    self.sende()
                }
            }
        }

        private func sende(immer: Bool = false) {
            guard !beendet, let f = fenster else { return }
            let zuSehen = sichtbar && f.isVisible && !f.isMiniaturized && f.occlusionState.contains(.visible)
            let p = Platz(tool: tool, prozess: getpid(), fenster: f.windowNumber,
                          bereich: Rechteck(f.convertToScreen(bereichImFenster)),
                          ziel: Rechteck(f.convertToScreen(zielImFenster)),
                          sichtbar: zuSehen, vorn: NSApp.isActive, ecken: ecken, bewegt: bewegt)
            guard immer || p != zuletzt else { return }
            zuletzt = p
            LoomnAndocken.sende(.platz, p)
        }
    }

    // MARK: - archivn-Seite

    /// Alle gemeldeten Andockstellen. Fragt beim Start nach, vergisst Fenster und Apps, die weg sind.
    @MainActor
    final class Verzeichnis {
        private(set) var plaetze: [String: Platz] = [:]
        /// Neue oder geänderte Andockstelle
        var beiPlatz: ((Platz) -> Void)?
        /// Andockstelle ist weg (Fenster zu, App beendet)
        var beiWeg: ((Int32, Int) -> Void)?
        private var beobachter: [(NotificationCenter, NSObjectProtocol)] = []

        static func schluessel(_ prozess: Int32, _ fenster: Int) -> String { "\(prozess)/\(fenster)" }

        init() {
            let dnc = DistributedNotificationCenter.default()
            let platz = LoomnAndocken.empfange(.platz, Platz.self) { [weak self] p in
                guard let self else { return }
                self.plaetze[Self.schluessel(p.prozess, p.fenster)] = p
                self.beiPlatz?(p)
            }
            let weg = LoomnAndocken.empfange(.weg, Weg.self) { [weak self] w in self?.entferne(w.prozess, w.fenster) }
            let ende = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for p in self.plaetze.values where p.prozess == pid { self.entferne(p.prozess, p.fenster) }
                }
            }
            beobachter = [(dnc, platz), (dnc, weg), (NSWorkspace.shared.notificationCenter, ende)]
            frage()
        }

        /// Alle Tools bitten, ihre Andockstellen neu zu melden
        func frage() { LoomnAndocken.sende(.frage, Frage()) }

        func platz(_ prozess: Int32, _ fenster: Int) -> Platz? { plaetze[Self.schluessel(prozess, fenster)] }

        /// Sichtbare Andockstelle, deren Ziel (mit etwas Spielraum) unter `punkt` liegt
        func ziel(bei punkt: NSPoint, spielraum: CGFloat = 16) -> Platz? {
            plaetze.values.first { $0.sichtbar && $0.ziel.rect.insetBy(dx: -spielraum, dy: -spielraum).contains(punkt) }
        }

        func melde(_ zustand: String, an p: Platz) {
            LoomnAndocken.sende(.zustand, Zustand(prozess: p.prozess, fenster: p.fenster, zustand: zustand))
        }

        private func entferne(_ prozess: Int32, _ fenster: Int) {
            guard plaetze.removeValue(forKey: Self.schluessel(prozess, fenster)) != nil else { return }
            beiWeg?(prozess, fenster)
        }
    }
}
