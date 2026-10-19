import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Vorschaubilder: ein Standbild und eine Bildreihe (8 Bilder nebeneinander) für die Vorschau
/// beim Drüberfahren. Liegen in der Mediathek (Archivdaten/Vorschauen) und als Kopie im
/// Zwischenspeicher auf dem Mac, damit man auch ohne SSD blättern kann. Jederzeit neu erzeugbar.
enum Previews {
    static let stripFrames = 8

    static func posterPath(_ id: String) -> String { "\(id.prefix(2))/\(id).jpg" }
    static func stripPath(_ id: String) -> String { "\(id.prefix(2))/\(id)-reihe.jpg" }

    /// Lokaler Zwischenspeicher je Mediathek: ~/Library/Caches/Loomn Archiv/<ID>/
    static func cacheRoot(libraryID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Loomn Archiv", isDirectory: true).appendingPathComponent(libraryID, isDirectory: true)
    }

    static func cacheDir(libraryID: String) -> URL {
        cacheRoot(libraryID: libraryID).appendingPathComponent("Vorschauen", isDirectory: true)
    }

    static func exists(_ id: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(posterPath(id)).path)
    }

    /// Vorschauen für ein Video erzeugen und in alle `dirs` schreiben.
    static func generate(video: URL, id: String, into dirs: [URL]) async throws {
        let asset = AVURLAsset(url: video)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 640, height: 640)

        func frame(_ t: Double) async -> CGImage? {
            try? await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
        }

        let posterTime = duration > 0 ? min(duration * 0.15, 3) : 0
        guard let poster = await frame(posterTime) else { throw FileOps.Failure("Kein Bild aus „\(video.lastPathComponent)“") }

        gen.maximumSize = CGSize(width: 360, height: 360)
        var frames: [CGImage] = []
        for i in 0..<stripFrames {
            let t = duration > 0 ? duration * (Double(i) + 0.5) / Double(stripFrames) : 0
            if let f = await frame(t) { frames.append(f) }
        }
        let strip = frames.isEmpty ? nil : makeStrip(frames)

        for dir in dirs {
            let p = dir.appendingPathComponent(posterPath(id))
            try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJPEG(poster, to: p)
            if let strip { try writeJPEG(strip, to: dir.appendingPathComponent(stripPath(id))) }
        }
    }

    private static func makeStrip(_ frames: [CGImage]) -> CGImage? {
        let w = frames[0].width, h = frames[0].height
        guard let ctx = CGContext(data: nil, width: w * frames.count, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        for (i, f) in frames.enumerated() {
            ctx.draw(f, in: CGRect(x: i * w, y: 0, width: w, height: h))
        }
        return ctx.makeImage()
    }

    static func writeJPEG(_ img: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FileOps.Failure("Vorschau lässt sich nicht schreiben")
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FileOps.Failure("Vorschau lässt sich nicht schreiben") }
    }

    /// Vorschau aus dem Zwischenspeicher, sonst von der SSD (und dann in den Zwischenspeicher kopieren).
    static func load(_ rel: String, cache: URL?, library: URL?) -> NSImage? {
        let fm = FileManager.default
        if let cache {
            let c = cache.appendingPathComponent(rel)
            if let img = NSImage(contentsOf: c) { return img }
            if let library {
                let l = library.appendingPathComponent(rel)
                guard fm.fileExists(atPath: l.path) else { return nil }
                try? fm.createDirectory(at: c.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: l, to: c)
                return NSImage(contentsOf: l)
            }
            return nil
        }
        return library.flatMap { NSImage(contentsOf: $0.appendingPathComponent(rel)) }
    }
}

/// Bildspeicher für die Oberfläche.
@MainActor
final class ThumbStore: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()
    private var loading = Set<String>()
    private var missing = Set<String>()
    /// Zählt hoch, wenn neue Bilder da sind (damit Kacheln neu zeichnen)
    @Published private(set) var generation = 0

    var cacheDir: URL?
    var libraryDir: URL?

    func reset(cacheDir: URL?, libraryDir: URL?) {
        self.cacheDir = cacheDir
        self.libraryDir = libraryDir
        cache.removeAllObjects()
        loading.removeAll()
        missing.removeAll()
        generation += 1
    }

    func invalidate(_ id: String) {
        cache.removeObject(forKey: Previews.posterPath(id) as NSString)
        cache.removeObject(forKey: Previews.stripPath(id) as NSString)
        missing.remove(Previews.posterPath(id))
        missing.remove(Previews.stripPath(id))
        generation += 1
    }

    func image(_ rel: String) -> NSImage? {
        if let img = cache.object(forKey: rel as NSString) { return img }
        guard !loading.contains(rel), !missing.contains(rel) else { return nil }
        loading.insert(rel)
        let c = cacheDir, l = libraryDir
        Task.detached(priority: .userInitiated) {
            let img = Previews.load(rel, cache: c, library: l)
            await MainActor.run {
                self.loading.remove(rel)
                if let img {
                    self.cache.setObject(img, forKey: rel as NSString)
                    self.generation += 1
                } else {
                    self.missing.insert(rel)
                }
            }
        }
        return nil
    }
}
