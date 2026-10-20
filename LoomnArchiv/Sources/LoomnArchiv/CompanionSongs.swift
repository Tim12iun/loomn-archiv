import SwiftUI

/// Song als Kachel im Kompagnon, genau so groß wie eine Videokachel. Ziehen nimmt die aktuelle Version mit.
struct CompanionSongTile: View {
    @EnvironmentObject var model: AppModel
    var song: SongItem
    @State private var hover = false

    var body: some View {
        let v = song.current
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                DS.surface
                Image(systemName: song.hasAudio ? "waveform" : "music.note")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(song.hasAudio ? DS.accent : DS.line)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 4) {
                    if let v { Badge("V\(v.number)", small: true) }
                    Spacer(minLength: 2)
                    if let d = v?.duration { Badge(d.clock, small: true) }
                }
                .padding(4)
            }
            .aspectRatio(4 / 5, contentMode: .fit)
            .clipShape(DS.shape)
            .overlay(DS.shape.strokeBorder(hover ? DS.accent : DS.line, lineWidth: 1))
            .onHover { hover = $0 }
            Text(song.title).font(DS.font(14, .bold)).lineLimit(1)
            Text(detail).font(DS.font(12)).foregroundStyle(DS.dim).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onDrag { model.songDragItem(song) }
    }

    private var detail: String {
        let n = model.songStats.count[song.id] ?? 0
        let versions = song.versions.count
        return "\(n) Videos" + (versions > 1 ? " · \(versions) Versionen" : "")
    }
}

/// Geöffneter Song: füllt die Fläche unter den Filtern. Oben fest die neueste Version (etwas größer),
/// darunter scrollbar die älteren. Jede Version anhören und als Audiodatei in andere Apps ziehen.
struct CompanionSongDetail: View {
    @EnvironmentObject var model: AppModel
    var song: SongItem
    var back: () -> Void
    @StateObject private var player = AudioPlayer()

    var body: some View {
        let sorted = song.versions.sorted { $0.number > $1.number }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(DS.surface, in: DS.shape)
                        .contentShape(DS.shape)
                }
                .buttonStyle(DSPress())
                .help("Zurück zu den Songs")
                Text(song.title).font(DS.font(17, .bold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            if let newest = sorted.first {
                row(newest, big: true)
            } else {
                Text("Noch kein Audio").font(DS.font(15, .bold)).foregroundStyle(DS.dim)
            }
            if sorted.count > 1 {
                Text("Ältere Versionen").dsLabel().padding(.top, 4)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sorted.dropFirst()) { v in row(v, big: false) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: song.id) { _, _ in player.stop() }
        .onDisappear { player.stop() }
    }

    private func row(_ v: SongVersion, big: Bool) -> some View {
        let url = model.audioURL(v)
        let on = url != nil && player.url == url && player.playing
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { if let url { player.toggle(url) } } label: {
                    Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: big ? 13 : 11, weight: .bold))
                        .foregroundStyle(DS.bg)
                        .frame(width: big ? 34 : 28, height: big ? 34 : 28)
                        .background(url == nil ? DS.dim : DS.accent, in: Circle())
                }
                .buttonStyle(DSPress())
                .disabled(url == nil)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("V\(v.number)").font(DS.font(big ? 17 : 15, .bold))
                        if v.id == song.current?.id { Text("aktuell").dsLabel(DS.accent) }
                    }
                    Text([v.added.day, v.duration.map(\.clock)].compactMap { $0 }.joined(separator: " · "))
                        .font(DS.font(12, .semibold)).foregroundStyle(DS.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "hand.draw").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.dim)
            }
            if big, let url {
                WaveformView(url: url, progress: player.url == url && player.duration > 0 ? player.time / player.duration : 0) { f in
                    player.play(url, at: f * max(player.url == url ? player.duration : (v.duration ?? 0), 0))
                }
                .frame(height: 40)
            }
        }
        .padding(big ? 10 : 8)
        .background(DS.surface, in: DS.shape)
        .contentShape(DS.shape)
        .onDrag { model.songDragItem(song, version: v) }
        .help(url == nil ? "Audio nicht erreichbar (SSD angeschlossen?)" : "Gedrückt halten und in eine andere App ziehen")
    }
}
