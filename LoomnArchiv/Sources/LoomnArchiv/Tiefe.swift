import Foundation

// Tiefen-Takes aus Loomn Cam (Art „LiDAR“).
//
// Ab Loomn Cam 0.26 steckt die Tiefe verlustfrei in der .mov selbst: hinter den normalen
// QuickTime-Boxen liegen auf oberster Ebene Loomn-Boxen (`uuid`, UUID „loomn-sidecar“) mit den
// früheren Begleitdateien (`ldepth`, `obj`, `lmatte`). Ältere Takes haben diese Dateien daneben
// liegen oder kommen als `…_Tiefen-Paket.zip`.
//
// Grundsatz: Die Datei wird nur gelesen, nie verändert (kein Remux, kein Umkodieren, keine
// Metadaten). Eigene Angaben stehen nur in der `.loomn.json` unter `source.loomnDepth`.

enum LoomnDepth {
    /// „loomn-sidecar“ + 00 00 01
    static let uuid: [UInt8] = [0x6C, 0x6F, 0x6F, 0x6D, 0x6E, 0x2D, 0x73, 0x69, 0x64, 0x65, 0x63, 0x61, 0x72, 0x00, 0x00, 0x01]
    /// Symbol für LiDAR (Punktraster wie die Lidar-Punkte), im Filter und auf den Kacheln
    static let symbol = "circle.grid.3x3.fill"
    /// Begleitdateien alter Takes (vor Loomn Cam 0.26), gehören zum selben Eintrag
    static let companionExts = ["ldepth", "obj", "lmatte"]

    // MARK: Boxen in der .mov

    struct Box: Codable, Equatable {
        var kind: String
        var offset: UInt64
        var size: UInt64
    }

    struct Scan: Equatable {
        var boxes: [Box] = []
        /// Loomn-Box kaputt oder abgeschnitten
        var damaged = false
        var depthWidth: Int?
        var depthHeight: Int?
        var depthVersion: Int?

        var kinds: [String] { boxes.map(\.kind) }
        var hasLossless: Bool { !damaged && kinds.contains("ldepth") }
    }

    /// Oberste Boxen durchgehen (Big Endian). Liest nur Köpfe, nie die ganze Datei, und darf bei
    /// kaputten oder fremden Dateien nie abstürzen.
    static func scan(_ url: URL) -> Scan {
        var s = Scan()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return s }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return s }
        var pos: UInt64 = 0
        var steps = 0
        while pos + 8 <= end, steps < 100_000 {
            steps += 1
            guard let head = read(fh, at: pos, count: 16), head.count >= 8 else { break }
            var size = UInt64(be32(head, 0))
            let type = String(bytes: head[4..<8], encoding: .ascii) ?? ""
            var headLen: UInt64 = 8
            if size == 1 {
                guard head.count >= 16 else { if type == "uuid" { s.damaged = true }; break }
                size = be64(head, 8)
                headLen = 16
            } else if size == 0 {
                size = end - pos
            }
            guard size >= headLen else { break }
            let truncated = size > end - pos
            if type == "uuid", let id = read(fh, at: pos + headLen, count: 16), id == uuid {
                // Loomn-Box: Kopf, UUID, 8 Byte Art, dann Inhalt
                let kindAt = pos + headLen + 16
                guard !truncated, size >= headLen + 24, let k = read(fh, at: kindAt, count: 8), k.count == 8 else {
                    s.damaged = true
                    break
                }
                let kind = String(bytes: k.prefix { $0 != 0 }, encoding: .ascii) ?? ""
                s.boxes.append(Box(kind: kind, offset: pos, size: size))
                if kind == "ldepth" {
                    let body = read(fh, at: kindAt + 8, count: 10) ?? []
                    if body.count >= 10, body[0..<4] == [0x4C, 0x44, 0x45, 0x50] {   // „LDEP“
                        s.depthVersion = le16(body, 4)
                        s.depthWidth = le16(body, 6)
                        s.depthHeight = le16(body, 8)
                    } else {
                        s.damaged = true
                    }
                }
            }
            if truncated { break }
            pos += size
        }
        return s
    }

    private static func read(_ fh: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard (try? fh.seek(toOffset: offset)) != nil, let d = try? fh.read(upToCount: count) else { return nil }
        return [UInt8](d)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        b[i...i + 3].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        b[i...i + 7].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }

    // MARK: Tiefen-Paket (zip)

    static func isPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip" && url.lastPathComponent.lowercased().contains("tiefen-paket")
    }

    /// `take.json` aus einem Tiefen-Paket lesen (ohne es auszupacken).
    static func packageTake(_ url: URL) -> JSONValue? {
        guard let list = unzip(["-Z1", url.path]) else { return nil }
        let names = String(decoding: list, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let entry = names.filter({ ($0 as NSString).lastPathComponent == "take.json" })
                .min(by: { $0.count < $1.count }),
              let data = unzip(["-p", url.path, entry]) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func unzip(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    // MARK: Was ist das für ein Take?

    /// Kennung der Aufnahme aus der Take-Beschreibung (`takeId`).
    static func takeID(_ take: JSONValue?) -> String? {
        take?["takeId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// LiDAR-Take: Take-Beschreibung mit `"kind": "depth"`, eine Loomn-Box in der Datei oder ein Tiefen-Paket.
    static func isLiDAR(take: JSONValue?, scan: Scan?, url: URL) -> Bool {
        if take?["kind"]?.string?.lowercased() == "depth" { return true }
        if let scan, !scan.boxes.isEmpty || scan.damaged { return true }
        return isPackage(url)
    }

    /// Begleitdateien eines alten Takes direkt neben der .mov (gleicher Name, andere Endung).
    static func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        let fm = FileManager.default
        return companionExts.compactMap { ext in
            let c = base.appendingPathExtension(ext)
            if fm.fileExists(atPath: c.path) { return c }
            // auch in Großbuchstaben (z. B. nach Umweg über Windows)
            let C = base.appendingPathExtension(ext.uppercased())
            return fm.fileExists(atPath: C.path) ? C : nil
        }
    }

    /// Alles zusammen, was archivn über einen Tiefen-Take wissen will. nil = kein LiDAR-Take.
    static func inspect(_ url: URL, take: JSONValue?) -> DepthInfo? {
        if isPackage(url) {
            let t = packageTake(url)
            return DepthInfo(state: .package, takeId: takeID(t) ?? takeID(take))
        }
        let scan = Self.scan(url)
        guard isLiDAR(take: take, scan: scan, url: url) else { return nil }
        let side = companions(of: url)
        var info = DepthInfo(state: .videoOnly, takeId: takeID(take))
        info.boxes = scan.kinds
        if scan.damaged {
            info.state = .damaged
        } else if scan.hasLossless {
            info.state = .lossless
            info.width = scan.depthWidth
            info.height = scan.depthHeight
            info.format = scan.depthVersion.map { "LDEP v\($0)" }
        } else if side.contains(where: { $0.pathExtension.lowercased() == "ldepth" }) {
            info.state = .sidecar
        }
        info.companions = side.map { DepthInfo.Companion(ext: $0.pathExtension.lowercased(), originalName: $0.lastPathComponent) }
        return info
    }
}

/// Angaben zur Tiefe eines LiDAR-Takes (in der Begleitdatei unter `source.loomnDepth`).
struct DepthInfo: Codable, Equatable {
    enum State: String, Codable {
        /// `ldepth`-Box in der .mov (ab Loomn Cam 0.26)
        case lossless
        /// nur die Tiefe als Videospur (1 cm), keine Box, keine .ldepth
        case videoOnly
        /// keine Box, aber eine .ldepth daneben (alter Take)
        case sidecar
        /// Loomn-Box kaputt oder abgeschnitten
        case damaged
        /// `…_Tiefen-Paket.zip`
        case package
    }

    /// Begleitdatei eines alten Takes, liegt in der Mediathek neben dem Video
    struct Companion: Codable, Equatable {
        var ext: String
        var originalName: String
        var file: String?
        var sha256: String?
        var size: Int64?
    }

    var state: State
    var takeId: String?
    var width: Int?
    var height: Int?
    var format: String?
    /// Arten der Loomn-Boxen in der Datei (ldepth, obj, lmatte)
    var boxes: [String] = []
    var companions: [Companion] = []

    /// Begleitdateien, deren Inhalt auch als Box in der .mov steckt (nur melden, nie löschen)
    var redundant: [String] { companions.map(\.ext).filter { boxes.contains($0) } }

    var label: String {
        switch state {
        case .lossless: return "Tiefe verlustfrei"
        case .videoOnly: return "Tiefe nur Videospur (1 cm)"
        case .sidecar: return "Tiefe verlustfrei (.ldepth daneben)"
        case .damaged: return "Tiefe beschädigt"
        case .package: return "Tiefen-Paket (zip)"
        }
    }

    var detail: String {
        var s = label
        if state == .lossless, let w = width, let h = height { s += " · \(w)×\(h)" }
        if let f = format, state == .lossless { s += " · \(f)" }
        return s
    }

    /// SF-Symbol für Liste und Details
    var symbol: String {
        switch state {
        case .lossless, .sidecar: return LoomnDepth.symbol
        case .videoOnly: return "circle.grid.3x3"
        case .damaged: return "exclamationmark.triangle.fill"
        case .package: return "shippingbox"
        }
    }

    static let key = "loomnDepth"

    var json: JSONValue? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    init(state: State, takeId: String? = nil) {
        self.state = state
        self.takeId = takeId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decode(State.self, forKey: .state)) ?? .videoOnly
        takeId = try c.decodeIfPresent(String.self, forKey: .takeId)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        boxes = try c.decodeIfPresent([String].self, forKey: .boxes) ?? []
        companions = try c.decodeIfPresent([Companion].self, forKey: .companions) ?? []
    }
}

extension VideoRecord {
    /// Tiefe eines LiDAR-Takes, nil bei normalen Videos
    var depth: DepthInfo? {
        get {
            guard let v = source?[DepthInfo.key], let d = try? JSONEncoder().encode(v) else { return nil }
            return try? JSONDecoder().decode(DepthInfo.self, from: d)
        }
        set {
            var s = source ?? [:]
            s[DepthInfo.key] = newValue?.json
            source = s.isEmpty ? nil : s
        }
    }

    /// LiDAR-Clip (Tiefen-Take aus Loomn Cam). Immer RAW, LiDAR ist ein Merkmal, keine eigene Art.
    var isLiDAR: Bool { source?[DepthInfo.key] != nil }

    /// Kennung der Aufnahme aus Loomn Cam (gleich für .mov und Tiefen-Paket desselben Takes)
    var takeID: String? { depth?.takeId ?? LoomnDepth.takeID(source?["loomnTake"]) }
}
