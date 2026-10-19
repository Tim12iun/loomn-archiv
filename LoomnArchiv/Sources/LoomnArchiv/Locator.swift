import Foundation

/// Findet eine Mediathek über ihre ID, nicht über den Pfad: so klappt es auch, wenn ein anderer Mac
/// die SSD unter einem anderen Namen oder Pfad einhängt.
enum Locator {
    /// Orte, an denen gesucht wird: alle angeschlossenen Laufwerke und der Benutzerordner.
    static func searchRoots(extra: [URL] = []) -> [URL] {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser
        return extra + vols.filter { $0.path != "/" } + [home]
    }

    /// Alle Mediatheken bis `depth` Ebenen unter `url`.
    static func libraries(under url: URL, depth: Int = 3) -> [URL] {
        if Library.isLibrary(url) { return [url] }
        guard depth > 0 else { return [] }
        let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        var out: [URL] = []
        for k in kids where (try? k.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            // Große Systemordner nicht durchsuchen
            if ["Library", "System", "Applications", "Material", "Archivdaten", "node_modules"].contains(k.lastPathComponent) { continue }
            out += libraries(under: k, depth: depth - 1)
        }
        return out
    }

    static func find(id: String, hint: URL?, extra: [URL] = []) -> URL? {
        if let hint, (try? Library.readManifest(hint))?.id == id { return hint }
        for root in searchRoots(extra: extra) {
            for lib in libraries(under: root, depth: root == FileManager.default.homeDirectoryForCurrentUser ? 2 : 3)
            where (try? Library.readManifest(lib))?.id == id {
                return lib
            }
        }
        return nil
    }
}

/// Lokale Kopie von Index und Katalog, damit man ohne SSD blättern und suchen kann.
/// Nur eine Kopie: die Wahrheit liegt immer auf der SSD.
enum OfflineCache {
    static func save(_ paths: LibraryPaths, id: String) {
        let fm = FileManager.default
        let dir = Previews.cacheRoot(libraryID: id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in [paths.manifest, paths.catalog, paths.index] where fm.fileExists(atPath: f.path) {
            let dst = dir.appendingPathComponent(f.lastPathComponent)
            let tmp = dir.appendingPathComponent(".\(f.lastPathComponent).tmp")
            try? fm.removeItem(at: tmp)
            if (try? fm.copyItem(at: f, to: tmp)) != nil {
                _ = try? fm.replaceItemAt(dst, withItemAt: tmp)
                if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: tmp, to: dst) }
            }
        }
    }

    static func load(id: String) -> (Manifest, Catalog, [VideoRecord])? {
        let dir = Previews.cacheRoot(libraryID: id)
        guard let m = try? Library.readManifest(dir),
              let cdata = try? Data(contentsOf: dir.appendingPathComponent("katalog.json")),
              let c = try? Sidecar.decoder.decode(Catalog.self, from: cdata),
              let ix = try? ArchiveIndex(url: dir.appendingPathComponent("index.sqlite"), readOnly: true),
              let recs = try? ix.all() else { return nil }
        return (m, c, recs.map { c.refresh($0) })
    }
}

/// Umzug der Mediathek an einen anderen Ort (z. B. größere SSD): alles kopieren, jedes Video per
/// Fingerabdruck prüfen. Das Original bleibt liegen, bis man es selbst löscht.
enum Relocation {
    static func copyLibrary(from src: URL, toParent parent: URL,
                            progress: @escaping (Double, String) -> Void) throws -> URL {
        let fm = FileManager.default
        let dst = parent.appendingPathComponent(src.lastPathComponent, isDirectory: true)
        guard !fm.fileExists(atPath: dst.path) else {
            throw FileOps.Failure("Am Ziel gibt es schon einen Ordner „\(src.lastPathComponent)“")
        }
        if dst.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") {
            throw FileOps.Failure("Das Ziel liegt innerhalb der Mediathek")
        }
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else {
            throw FileOps.Failure("Mediathek nicht lesbar")
        }
        var files: [(URL, Int64)] = []
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true { continue }
            if u.lastPathComponent.hasSuffix(".part") || u.lastPathComponent == ".DS_Store" { continue }
            files.append((u, Int64(v?.fileSize ?? 0)))
        }
        let total = max(files.reduce(0) { $0 + $1.1 }, 1)
        if let free = FileOps.freeSpace(parent), free < total + 1024 * 1024 * 1024 {
            throw FileOps.Failure("Nicht genug Platz am Ziel (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) nötig)")
        }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var done: Int64 = 0
        for (u, size) in files {
            let rel = Library.relative(u, to: src)
            let target = dst.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress(Double(done) / Double(total), rel)
            let sidecar = Sidecar.url(forVideo: u)
            if !u.lastPathComponent.hasSuffix(Sidecar.suffix), fm.fileExists(atPath: sidecar.path),
               let r = try? Sidecar.read(sidecar), r.file == u.lastPathComponent, !r.sha256.isEmpty {
                try FileOps.copyVerified(u, to: target, sha: r.sha256)
            } else {
                try fm.copyItem(at: u, to: target)
                guard FileOps.size(target) == size else { throw FileOps.Failure("Kopie von „\(rel)“ unvollständig") }
            }
            done += size
        }
        progress(1, "Fertig")
        return dst
    }
}
