import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Dateinamen und Ablageordner

enum Naming {
    private static func formatter(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.calendar = Calendar(identifier: .gregorian)
        d.timeZone = .current
        d.dateFormat = f
        return d
    }

    /// Material/JJJJ/JJJJ-MM/JJJJ-MM-TT
    static func dayFolder(_ date: Date) -> String {
        "Material/\(formatter("yyyy").string(from: date))/\(formatter("yyyy-MM").string(from: date))/\(formatter("yyyy-MM-dd").string(from: date))"
    }

    /// Lesbarer Teil für den Dateinamen: ohne Sonderzeichen, Leerzeichen als Bindestrich.
    static func clean(_ s: String, max: Int = 40) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|_.,;'`´#%&{}[]()!$@=+~^")
            .union(.controlCharacters).union(.newlines)
        var out = s.components(separatedBy: bad).joined(separator: " ")
        out = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: "-")
        if out.count > max { out = String(out.prefix(max)) }
        return out.isEmpty ? "x" : out
    }

    static func songPart(_ r: VideoRecord) -> String {
        r.songs.first.map { clean($0.title) } ?? "ohne-Song"
    }

    /// 2026-10-13_1502_RAW_Songname_8f3a.mov
    static func fileName(record r: VideoRecord, shortID: String, ext: String) -> String {
        let stamp = formatter("yyyy-MM-dd_HHmm").string(from: r.createdAt)
        let e = ext.isEmpty ? "" : "." + ext.lowercased()
        return "\(stamp)_\(clean(r.kind.name, max: 12))_\(songPart(r))_\(shortID)\(e)"
    }

    /// Neuer Name nach Änderung von Art oder Song. Datum, Uhrzeit und Kennung bleiben.
    /// nil, wenn der Name nicht dem Schema folgt (dann bleibt er, wie er ist).
    static func renamed(_ file: String, record r: VideoRecord) -> String? {
        let ext = (file as NSString).pathExtension
        let base = (file as NSString).deletingPathExtension
        let parts = base.components(separatedBy: "_")
        guard parts.count == 5, parts[0].count == 10, parts[1].count == 4 else { return nil }
        let e = ext.isEmpty ? "" : "." + ext
        return "\(parts[0])_\(parts[1])_\(clean(r.kind.name, max: 12))_\(songPart(r))_\(parts[4])\(e)"
    }

    /// Faustregel für die Art aus dem Dateinamen.
    static func guessKind(_ name: String) -> String? {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["final", "export", "reel", "fertig", "upload"]) { return Kind.final }
        if has(["edit", "fx", "effekt", "grade", "color"]) { return Kind.edit }
        if has(["cut", "schnitt", "trim"]) { return Kind.cut }
        if has(["raw", "roh", "img_", "dji_", "c0", "mvi_", "gopr", "take"]) { return Kind.raw }
        return nil
    }
}

// MARK: - Dateien prüfen, kopieren, Metadaten lesen

enum FileOps {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "mxf", "hevc", "3gp", "webm", "mpg", "mpeg", "braw", "r3d", "insv", "lrv"]

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext) { return t.conforms(to: .movie) || t.conforms(to: .video) }
        return false
    }

    /// Dateien und Ordner (rekursiv) zu einer Liste von Videos auflösen.
    static func collectVideos(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let en = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let f as URL in en where isVideo(f) { out.append(f) }
            } else if isVideo(u) {
                out.append(u)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
    }

    /// SHA-256 als Hex. `uncached`: an der Zwischenablage des Systems vorbei direkt von der Platte
    /// lesen (für die Prüfung der Kopie).
    static func sha256(_ url: URL, uncached: Bool = false, progress: ((Int64) -> Void)? = nil) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw Failure("„\(url.lastPathComponent)“ lässt sich nicht lesen") }
        defer { close(fd) }
        if uncached { _ = fcntl(fd, F_NOCACHE, 1) }
        var hasher = SHA256()
        let chunk = 8 * 1024 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        var total: Int64 = 0
        while true {
            let n = read(fd, buf, chunk)
            if n < 0 { throw Failure("Lesefehler bei „\(url.lastPathComponent)“") }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            total += Int64(n)
            progress?(total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Freier Platz auf dem Laufwerk von `url`.
    static func freeSpace(_ url: URL) -> Int64? {
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, v > 0 {
            return v
        }
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity { return Int64(v) }
        return nil
    }

    static func totalSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map { Int64($0 ?? 0) }
    }

    static func volumeName(_ url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
    }

    static func isInternal(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRootFileSystemKey])
        return v?.volumeIsRootFileSystem == true || (v?.volumeIsInternal == true)
    }

    /// Kopiert `src` nach `dst` und prüft die Kopie per Fingerabdruck direkt von der Platte.
    static func copyVerified(_ src: URL, to dst: URL, sha: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: src, to: dst)
        let check = try sha256(dst, uncached: true)
        guard check == sha else {
            try? fm.removeItem(at: dst)
            throw Failure("Kopie von „\(src.lastPathComponent)“ fehlerhaft (Fingerabdruck stimmt nicht), nichts übernommen")
        }
    }
}

// MARK: - Video-Metadaten

struct Probe {
    var createdAt: Date
    var createdAtSource: String
    var media: MediaInfo
    /// Take-Beschreibung aus Loomn Cam (`de.loomn.take`), falls vorhanden
    var loomnTake: JSONValue?

    static func load(_ url: URL) async -> Probe {
        let asset = AVURLAsset(url: url)
        var created: Date?
        var take: JSONValue?

        if let item = try? await asset.load(.creationDate) {
            created = try? await item.load(.dateValue)
            if created == nil, let s = try? await item.load(.stringValue) { created = Sidecar.parseDate(s) }
        }
        let meta = (try? await asset.load(.metadata)) ?? []
        for item in meta {
            let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
            if created == nil, key.contains("creationdate") || item.commonKey == .commonKeyCreationDate {
                if let d = try? await item.load(.dateValue) { created = d }
                else if let s = try? await item.load(.stringValue) { created = Sidecar.parseDate(s) }
            }
            if key.hasSuffix("de.loomn.take"), let s = try? await item.load(.stringValue),
               let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) {
                take = v
            }
        }

        var source = "metadata"
        if created == nil {
            source = "file"
            let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let c = v?.creationDate, m = v?.contentModificationDate
            // Erstelldatum der Datei; ist die Änderung älter (Kopie), die nehmen
            if let c, let m { created = min(c, m) } else { created = c ?? m }
        }

        var media = MediaInfo()
        if let d = try? await asset.load(.duration), d.isNumeric { media.duration = d.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if case let (size, t)? = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: size).applying(t)
                media.width = Int(abs(r.width).rounded())
                media.height = Int(abs(r.height).rounded())
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { media.fps = Double(fps) }
            if let fd = try? await track.load(.formatDescriptions).first {
                let code = CMFormatDescriptionGetMediaSubType(fd)
                let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xff))) }
                media.codec = String(chars).trimmingCharacters(in: .whitespaces)
            }
        }
        return Probe(createdAt: created ?? Date(), createdAtSource: source, media: media, loomnTake: take)
    }
}

// MARK: - Ein Video ins Archiv übernehmen

enum ImportResult {
    case imported(VideoRecord)
    case duplicate(existingID: String)
}

enum Importer {
    /// Kopiert ein Video in die Mediathek: Fingerabdruck, Duplikat-Prüfung, geprüfte Kopie in den
    /// Tagesordner, Begleitdatei, Index. Das Original bleibt unverändert.
    static func importFile(_ src: URL, sha knownSHA: String?, attrs: Attrs, into lib: Library,
                           source extra: [String: JSONValue] = [:], allowDuplicate: Bool = false,
                           progress: @escaping (String) -> Void = { _ in }) async throws -> ImportResult {
        let fm = FileManager.default
        progress("Fingerabdruck")
        let sha = try knownSHA ?? FileOps.sha256(src)
        // Import aus dem Fenster: Das Archiv ist reiner Speicher, nichts wird abgelehnt.
        // Nur der automatische Eingang aus den Tools überspringt gleiche Dateien.
        if !allowDuplicate {
            if let existing = await lib.duplicate(of: sha) { return .duplicate(existingID: existing) }
            guard await lib.reserve(sha) else { return .duplicate(existingID: await lib.duplicate(of: sha) ?? "") }
        }

        do {
            let size = FileOps.size(src)
            if let free = FileOps.freeSpace(lib.root), free < size + 512 * 1024 * 1024 {
                throw FileOps.Failure("Nicht genug Platz auf der SSD für „\(src.lastPathComponent)“")
            }
            progress("Metadaten")
            let probe = await Probe.load(src)
            let catalog = await lib.currentCatalog()
            var r = VideoRecord(id: Catalog.newID(), file: "", originalName: src.lastPathComponent, sha256: sha, size: size,
                                createdAt: probe.createdAt, createdAtSource: probe.createdAtSource, importedAt: Date(),
                                kind: Ref(id: Kind.raw, name: "RAW"), songs: [], format: Ref(id: "", name: ""), moods: [],
                                media: probe.media,
                                source: probe.loomnTake.map { ["loomnTake": $0] })
            attrs.apply(to: &r, catalog: catalog)
            if !extra.isEmpty { r.source = (r.source ?? [:]).merging(extra) { _, neu in neu } }

            let dir = lib.paths.url(Naming.dayFolder(r.createdAt))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let part = dir.appendingPathComponent(".\(r.id).part")
            progress("Kopieren und prüfen")
            try FileOps.copyVerified(src, to: part, sha: sha)
            do {
                let rec = try await lib.commit(part: part, record: r, ext: src.pathExtension)
                return .imported(rec)
            } catch {
                try? fm.removeItem(at: part)
                throw error
            }
        } catch {
            await lib.release(sha)
            throw error
        }
    }
}
