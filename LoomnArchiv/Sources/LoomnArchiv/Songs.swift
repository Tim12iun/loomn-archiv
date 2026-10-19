import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Audiodateien der Songs: liegen unverändert unter Songs/<Song>_<Kennung>/ in der Mediathek,
/// eine Datei je Version, daneben eine Begleitdatei mit Titel und allen Versionen.
enum SongAudio {
    static let extensions: Set<String> = ["wav", "mp3", "aif", "aiff", "m4a", "flac", "caf"]
    static let sidecarName = "song.loomn-song.json"

    static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .audio) ?? false
    }

    static func folderName(_ s: SongItem) -> String {
        "\(Naming.clean(s.title))_\(s.id.replacingOccurrences(of: "-", with: "").prefix(4))"
    }

    static func duration(_ url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let s = d.seconds
        return s.isFinite && s > 0 ? s : nil
    }

    /// Begleitdateien der Songs mit Audio auf Stand bringen (nur schreiben, was sich geändert hat).
    static func writeSidecars(_ c: Catalog, paths: LibraryPaths) {
        for s in c.songs {
            guard let v = s.versions.first else { continue }
            let url = paths.url(v.file).deletingLastPathComponent().appendingPathComponent(sidecarName)
            guard let data = try? Sidecar.encoder.encode(s) else { continue }
            if (try? Data(contentsOf: url)) != data { try? Sidecar.atomicWrite(data, to: url) }
        }
    }

    /// Katalog verloren: Songs mit Audio aus ihren Begleitdateien zurückholen.
    static func absorbSidecars(into c: inout Catalog, paths: LibraryPaths) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.songs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent(sidecarName)),
                  let s = try? Sidecar.decoder.decode(SongItem.self, from: data) else { continue }
            if let i = c.songs.firstIndex(where: { $0.id == s.id }) {
                for v in s.versions where !c.songs[i].versions.contains(where: { $0.id == v.id }) { c.songs[i].versions.append(v) }
                if c.songs[i].currentVersionID == nil { c.songs[i].currentVersionID = s.currentVersionID }
            } else {
                c.songs.append(s)
            }
        }
    }
}

extension Library {
    /// Audiodatei prüfen, kopieren und als Version ablegen. Ohne `songID` wird der Song angelegt
    /// (oder ein gleichnamiger Song ohne Audio bekommt seine erste Datei).
    func addSongAudio(to songID: String?, title: String, from src: URL, duration: Double?) throws -> SongItem {
        let fm = FileManager.default
        guard SongAudio.isAudio(src) else { throw FileOps.Failure("„\(src.lastPathComponent)“ ist keine Audiodatei (WAV, MP3, AIFF, M4A)") }
        let sha = try FileOps.sha256(src)
        var c = currentCatalog()
        // Dieselbe Datei darf bei mehreren Songs liegen, nur nicht doppelt beim selben Song
        if let songID, c.song(songID)?.versions.contains(where: { $0.sha256 == sha }) == true {
            throw FileOps.Failure("Diese Datei ist bei diesem Song schon als Version hinterlegt")
        }
        var song: SongItem
        if let songID, let s = c.song(songID) {
            song = s
        } else {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw FileOps.Failure("Bitte einen Namen eingeben") }
            if let s = c.songs.first(where: { $0.title.compare(t, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                if s.hasAudio { throw FileOps.Failure("„\(s.title)“ gibt es schon. Neue Versionen gehen auf der Song-Seite.") }
                song = s
            } else {
                song = SongItem(title: t)
            }
        }
        let size = FileOps.size(src)
        if let free = FileOps.freeSpace(paths.root), free < size + 256 * 1024 * 1024 {
            throw FileOps.Failure("Nicht genug Platz auf der SSD")
        }
        // Ordner der ersten Version behalten, auch wenn der Song später umbenannt wurde
        let dir = song.versions.first.map { paths.url($0.file).deletingLastPathComponent() }
            ?? paths.songs.appendingPathComponent(SongAudio.folderName(song), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = (song.versions.map(\.number).max() ?? 0) + 1
        let ext = src.pathExtension.lowercased()
        let base = "\(Naming.clean(song.title))_v\(n)_\(Naming.dayFolder(Date()).split(separator: "/").last ?? "")"
        var final = dir.appendingPathComponent("\(base).\(ext)")
        var k = 2
        while fm.fileExists(atPath: final.path) { final = dir.appendingPathComponent("\(base)-\(k).\(ext)"); k += 1 }
        let part = dir.appendingPathComponent(".\(UUID().uuidString).part")
        try FileOps.copyVerified(src, to: part, sha: sha)
        try fm.moveItem(at: part, to: final)

        let v = SongVersion(id: Catalog.newID(), number: n, file: Self.relative(final, to: paths.root),
                            originalName: src.lastPathComponent, sha256: sha, size: size, added: Date(), duration: duration)
        song.versions.append(v)
        song.currentVersionID = v.id
        song.hidden = false
        if let i = c.songs.firstIndex(where: { $0.id == song.id }) { c.songs[i] = song } else { c.songs.append(song) }
        do {
            try setCatalog(c)
        } catch {
            try? fm.removeItem(at: final)
            throw error
        }
        return song
    }
}

// MARK: - Abspielen

/// Immer nur eins spielt: Wer startet, stoppt das vorher Laufende und setzt es auf den Anfang zurück.
@MainActor
enum NowPlaying {
    private static weak var owner: AnyObject?
    private static var stopOwner: (() -> Void)?

    static func claim(_ who: AnyObject, stop: @escaping () -> Void) {
        if let owner, owner !== who { stopOwner?() }
        owner = who
        stopOwner = stop
    }
}

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var url: URL?
    @Published private(set) var playing = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ u: URL) {
        if u == url, let player {
            if player.isPlaying { player.pause(); playing = false; stopTimer() } else { claim(); player.play(); playing = true; startTimer() }
            return
        }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: u) else { return }
        p.delegate = self
        player = p
        url = u
        duration = p.duration
        claim()
        p.play()
        playing = true
        startTimer()
    }

    func seek(_ t: Double) {
        player?.currentTime = t
        time = t
    }

    /// An eine Stelle springen; lädt die Datei, wenn nötig, und spielt ab
    func play(_ u: URL, at t: Double) {
        if u != url { toggle(u) }
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        time = p.currentTime
        if !p.isPlaying { claim(); p.play(); playing = true; startTimer() }
    }

    private func claim() { NowPlaying.claim(self) { [weak self] in self?.stop() } }

    func stop() {
        player?.stop()
        player = nil
        url = nil
        playing = false
        time = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let p = self.player { self.time = p.currentTime } }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = false; self.time = 0; self.stopTimer() }
    }
}

// MARK: - Bausteine

/// Gestricheltes Feld: Audiodatei reinziehen oder klicken zum Auswählen.
struct AudioDropZone: View {
    var title = "WAV oder MP3 hierher ziehen"
    var height: CGFloat = 96
    var pick: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        Button { if let u = Self.choose() { pick(u) } } label: {
            VStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .semibold))
                Text(title).font(DS.controlFont)
            }
            .foregroundStyle(targeted ? DS.accent : DS.text)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(targeted ? DS.accent.opacity(0.1) : DS.surface, in: DS.shape)
            .overlay(DS.shape.stroke(targeted ? DS.accent : DS.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(DS.shape)
        }
        .buttonStyle(DSPress())
        .audioDrop(targeted: $targeted, perform: pick)
    }

    @MainActor
    static func choose() -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.message = "Audiodatei des Songs wählen (WAV, MP3, AIFF, M4A)"
        return p.runModal() == .OK ? p.url : nil
    }
}

extension View {
    /// Nimmt eine reingezogene Audiodatei an.
    func audioDrop(targeted: Binding<Bool>, perform: @escaping (URL) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: targeted) { providers in
            RootView.loadURLs(providers) { urls in if let u = urls.first(where: SongAudio.isAudio) { perform(u) } }
            return true
        }
    }
}

/// Neuer Song: Name und Audiodatei, beides Pflicht.
struct NewSongSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var initialTitle = ""
    var created: (SongItem) -> Void = { _ in }
    @State private var title = ""
    @State private var file: URL?
    @State private var working = false
    @State private var error: String?

    private var name: String { title.trimmingCharacters(in: .whitespaces) }
    private var existing: SongItem? {
        model.catalog.songs.first { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    private var ready: Bool { !name.isEmpty && file != nil && !working && !(existing?.hasAudio ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Neuer Song").font(DS.font(30, .bold))
            Block(title: "Name", required: true, missing: name.isEmpty) {
                DSField(placeholder: "Songname", text: $title, onSubmit: create)
            }
            Block(title: "Audiodatei", required: true, missing: file == nil) {
                if let file {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.accent)
                        Text(file.lastPathComponent).font(DS.controlFont).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(FileOps.size(file).bytes).dsLabel()
                        Button { self.file = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.dim)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: DS.control)
                    .background(DS.surface, in: DS.shape)
                } else {
                    AudioDropZone { u in
                        file = u
                        if name.isEmpty { title = u.deletingPathExtension().lastPathComponent }
                    }
                }
            }
            if let e = existing, !name.isEmpty {
                Text(e.hasAudio ? "„\(e.title)“ gibt es schon. Neue Versionen lädst du auf der Song-Seite hoch."
                                : "„\(e.title)“ gibt es schon ohne Audio. Die Datei wird dort ergänzt.")
                    .font(DS.font(15, .semibold)).foregroundStyle(e.hasAudio ? DS.amber : DS.dim)
            }
            if let error { Text(error).font(DS.font(15, .semibold)).foregroundStyle(DS.amber) }
            HStack(spacing: DS.gap) {
                if working { ProgressView().controlSize(.small); Text("Wird kopiert und geprüft …").dsLabel() }
                Spacer()
                DSButton("Abbrechen") { dismiss() }.frame(width: 150).keyboardShortcut(.cancelAction)
                DSButton("Anlegen", icon: "plus", fill: ready ? DS.accent : nil) { create() }
                    .frame(width: 180).disabled(!ready)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(DS.bg)
        .foregroundStyle(DS.text)
        .preferredColorScheme(.dark)
        .onAppear { if title.isEmpty { title = initialTitle } }
    }

    private func create() {
        guard ready, let file else { return }
        working = true
        error = nil
        Task {
            do {
                let s = try await model.addSongAudio(to: existing?.id, title: name, from: file)
                created(s)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}

// MARK: - Song-Kopf auf der Song-Seite

/// Player, aktuelle Version, ältere Versionen und „Neue Version“. Ohne Audio: Hinweis zum Nachreichen.
struct SongHeader: View {
    @EnvironmentObject var model: AppModel
    var song: SongItem
    @StateObject private var player = AudioPlayer()
    @State private var targeted = false
    @State private var showOlder = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cur = song.current {
                current(cur)
                if song.versions.count > 1 { older(cur) }
            } else {
                missing
            }
            if working { Text("Wird kopiert und geprüft …").dsLabel() }
            if let error { Text(error).font(DS.font(14, .semibold)).foregroundStyle(DS.amber) }
        }
        .padding(12)
        .background(targeted ? DS.accent.opacity(0.1) : DS.surface, in: DS.shape)
        .overlay(DS.shape.stroke(targeted ? DS.accent : (song.hasAudio ? Color.clear : DS.amber.opacity(0.5)), lineWidth: 1.5))
        .audioDrop(targeted: $targeted, perform: add)
        .onChange(of: song.id) { _, _ in player.stop(); showOlder = false; error = nil }
        .onDisappear { player.stop() }
    }

    private var missing: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(DS.amber)
            Text("Audio fehlt").font(DS.font(18, .bold))
            Spacer()
            DSButton("Datei wählen", icon: "waveform") { if let u = AudioDropZone.choose() { add(u) } }.frame(width: 200)
        }
    }

    private func current(_ v: SongVersion) -> some View {
        let url = model.audioURL(v)
        let loaded = url != nil && player.url == url
        let total = loaded ? player.duration : (v.duration ?? 0)
        return HStack(spacing: 12) {
            playButton(url, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("V\(v.number)").font(DS.font(18, .bold))
                    Text("aktuell").dsLabel(DS.accent)
                    Text("\(v.added.day) · \(v.originalName)").dsLabel().lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    // Wellenform ist die Zeitleiste: Klick oder Ziehen springt, gespielter Teil orange
                    WaveformView(url: url, progress: loaded && total > 0 ? player.time / total : 0) { f in
                        guard let url else { return }
                        player.play(url, at: f * total)
                    }
                    .frame(height: 46)
                    Text("\((loaded ? player.time : 0).clock) / \(total > 0 ? total.clock : "–")")
                        .font(DS.font(14, .semibold)).monospacedDigit().foregroundStyle(DS.dim)
                }
            }
            fileChip(v, url: url)
            DSButton("Neue Version", icon: "plus") { if let u = AudioDropZone.choose() { add(u) } }.frame(width: 190)
        }
    }

    private func older(_ cur: SongVersion) -> some View {
        let list = song.versions.filter { $0.id != cur.id }.sorted { $0.number > $1.number }
        return VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showOlder.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showOlder ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .bold))
                    Text("Ältere Versionen (\(list.count))").dsLabel()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.dim)
            if showOlder {
                ForEach(list) { v in
                    let url = model.audioURL(v)
                    HStack(spacing: 10) {
                        playButton(url, size: 30)
                        Text("V\(v.number)").font(DS.font(16, .bold))
                        Text("\(v.added.day) · \(v.originalName)").dsLabel().lineLimit(1).truncationMode(.middle)
                        if let d = v.duration { Text(d.clock).dsLabel().monospacedDigit() }
                        Spacer(minLength: 4)
                        fileChip(v, url: url)
                        Button { setCurrent(v) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.up").font(.system(size: 12, weight: .bold))
                                Text("Diese verwenden").font(DS.controlFont)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: DS.control)
                            .background(DS.surfaceHi, in: DS.shape)
                            .contentShape(DS.shape)
                        }
                        .buttonStyle(DSPress())
                        .fixedSize()
                        .help("Diese Version wieder zur aktuellen machen")
                    }
                    .padding(.leading, 6)
                }
            }
        }
    }

    private func playButton(_ url: URL?, size: CGFloat) -> some View {
        let on = url != nil && player.url == url && player.playing
        return Button { if let url { player.toggle(url) } } label: {
            Image(systemName: on ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(DS.bg)
                .frame(width: size, height: size)
                .background(url == nil ? DS.dim : DS.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(DSPress())
        .disabled(url == nil)
        .help(url == nil ? "Datei nicht erreichbar (SSD angeschlossen?)" : (on ? "Pause" : "Abspielen"))
    }

    /// Datei zum Rausziehen (z. B. in den Schnitt), Klick zeigt sie im Finder.
    private func fileChip(_ v: SongVersion, url: URL?) -> some View {
        Button { if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 13, weight: .semibold))
                Text((url?.pathExtension ?? "").uppercased()).font(DS.label)
            }
            .padding(.horizontal, 10)
            .frame(height: DS.control)
            .background(DS.surfaceHi, in: DS.shape)
            .contentShape(DS.shape)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onDrag { url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .help("Rausziehen in andere Programme, Klick zeigt die Datei im Finder")
    }

    private func setCurrent(_ v: SongVersion) {
        model.updateCatalog { c in if let i = c.songs.firstIndex(where: { $0.id == song.id }) { c.songs[i].currentVersionID = v.id } }
    }

    private func add(_ u: URL) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do { _ = try await model.addSongAudio(to: song.id, title: song.title, from: u) } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

// MARK: - Wellenform

/// Pegel einer Audiodatei, auf wenige Balken verdichtet (einmal je Datei gerechnet).
@MainActor
enum Waveform {
    private static var cache: [URL: [Float]] = [:]

    static func cached(_ url: URL) -> [Float]? { cache[url] }

    static func load(_ url: URL, bars: Int = 180) async -> [Float] {
        if let c = cache[url] { return c }
        let peaks = await Task.detached(priority: .utility) { compute(url, bars: bars) }.value
        cache[url] = peaks
        return peaks
    }

    nonisolated static func compute(_ url: URL, bars: Int) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65_536) else { return [] }
        let total = f.length
        let chans = Int(f.processingFormat.channelCount)
        var out = [Float](repeating: 0, count: bars)
        var pos: Int64 = 0
        while pos < total {
            do { try f.read(into: buf) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if let ch = buf.floatChannelData {
                var i = 0
                while i < n {
                    var v: Float = 0
                    for c in 0..<chans { v = max(v, abs(ch[c][i])) }
                    let b = min(bars - 1, Int((pos + Int64(i)) * Int64(bars) / total))
                    if v > out[b] { out[b] = v }
                    i += 8
                }
            }
            pos += Int64(n)
        }
        let m = out.max() ?? 0
        return m > 0 ? out.map { $0 / m } : out
    }
}

/// Wellenform wie bei SoundCloud: Balken, gespielter Teil orange, Klick oder Ziehen springt.
struct WaveformView: View {
    var url: URL?
    var progress: Double
    var seek: (Double) -> Void
    @State private var peaks: [Float] = []

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                let bars = peaks.isEmpty ? [Float](repeating: 0.08, count: 120) : peaks
                let step = size.width / CGFloat(bars.count)
                let w = max(1, step * 0.6)
                for (i, p) in bars.enumerated() {
                    let h = max(2, CGFloat(p) * size.height)
                    let x = CGFloat(i) * step
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                    let played = (x + w / 2) / size.width <= progress
                    ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(played ? DS.accent : DS.dim.opacity(0.55)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                seek(min(max(v.location.x / max(g.size.width, 1), 0), 1))
            })
        }
        .task(id: url) {
            guard let url else { peaks = []; return }
            peaks = Waveform.cached(url) ?? []
            if peaks.isEmpty { peaks = await Waveform.load(url) }
        }
        .help("Klicken oder ziehen zum Springen")
    }
}
