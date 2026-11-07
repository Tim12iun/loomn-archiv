import AVFoundation
import CoreImage

/// `LoomnArchiv --selftest <ordner>`: prüft ohne Oberfläche alles, was das Archiv über Jahre
/// tragen muss: Anlegen, Import mit geprüfter Kopie, Ablage nach Tag, Dateinamen, Begleitdateien,
/// Duplikate, Suche, Bearbeiten, Umbenennen von Listen, Index-Neuaufbau, Katalog-Verlust,
/// Umzug unter anderem Pfad, Kopieren der Mediathek, Versionsschutz, Offline-Kopie, Vorschauen.
enum SelfTest {
    struct Fail: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// `LoomnArchiv --updatetest <build>`: kommt Build <build> (oder neuer) über GitHub an und
    /// ließe er sich installieren?
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest") else { return }
        let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "loomn-archiv-test")
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                try await run(dir)
                print("SELBSTTEST OK")
            } catch {
                print("FEHLER: \(error.localizedDescription)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        exit(code)
    }

    static func check(_ ok: Bool, _ msg: String) throws {
        guard ok else { throw Fail(msg) }
        print("  ✓ \(msg)")
    }

    static func run(_ dir: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let src = dir.appendingPathComponent("Mac-Downloads", isDirectory: true)
        let ssdA = dir.appendingPathComponent("SSD-A", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: ssdA, withIntermediateDirectories: true)

        print("Testvideos erzeugen")
        let v1 = src.appendingPathComponent("IMG_0001.mov")
        let v2 = src.appendingPathComponent("song_final_export.mp4")
        let v3 = src.appendingPathComponent("Clip mit Leerzeichen.mov")
        let v4 = src.appendingPathComponent("noch eins.mov")
        try await makeVideo(v1, hue: 0.0, creation: "2025-03-07T14:30:00+01:00", loomnTake: true)
        try await makeVideo(v2, hue: 0.3, creation: nil, loomnTake: false, type: .mp4)
        try await makeVideo(v3, hue: 0.6, creation: "2024-12-31T23:10:00+01:00", loomnTake: false)
        try await makeVideo(v4, hue: 0.8, creation: "2025-03-07T09:00:00+01:00", loomnTake: false)
        let v1sha = try FileOps.sha256(v1)
        let v1mod = try v1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        print("Mediathek anlegen")
        var lib = try Library.create(in: ssdA)
        let libID = await lib.id
        try check(fm.fileExists(atPath: lib.paths.manifest.path) && fm.fileExists(atPath: lib.paths.catalog.path), "Kennung und Katalog angelegt")
        var cat = await lib.currentCatalog()
        try check(cat.formats.count == Catalog.defaultFormats.count && cat.moods.count == Catalog.defaultMoods.count, "Start-Listen vorhanden")
        try check(SongSearch.score("nacht", "Nachtfahrt") > SongSearch.score("nacht", "Gute Nacht Freunde")
                  && SongSearch.score("NCHTF", "Nachtfahrt · Lion") > 0 && SongSearch.score("über", "Uber Alles") > 0
                  && SongSearch.score("fahrt lion", "Nachtfahrt · Lion") > 0 && SongSearch.score("xyz", "Nachtfahrt") == 0,
                  "Songsuche findet Teilwörter, Lücken und Akzente")
        try check(cat.visibleMoods.map(\.name) == ["ruhig", "energetisch", "dunkel"] && cat.format(cat.formats.first { $0.name == "Splitscreen" }?.id) != nil, "Drei Start-Moods, Format Splitscreen")
        do {
            // Alter Katalog (Stand 1): ungenutzte alte Moods ausblenden, benutzte behalten, Splitscreen ergänzen
            var old = Catalog.makeDefault()
            old.defaultsVersion = 1
            old.formats.removeAll { $0.name == "Splitscreen" }
            let warm = old.addMood("warm"), roh = old.addMood("roh"), eigen = old.addMood("neblig")
            let lyric = old.addFormat("Lyric"), broll = old.addFormat("B-Roll")
            let data = try JSONEncoder().encode(old)
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            json.removeValue(forKey: "defaultsVersion")
            var up = try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: json))
            let changed = up.upgradeDefaults(usedMoodIDs: [roh.id], usedFormatIDs: [broll.id])
            let vis = Set(up.visibleMoods.map(\.id))
            let visF = Set(up.visibleFormats.map(\.id))
            try check(!visF.contains(lyric.id) && visF.contains(broll.id) && up.visibleFormats.contains { $0.name == "Slow-Mo" },
                      "Alte Mediathek: ungenutzte alte Formate weg, benutzte bleiben")
            try check(!up.formats.contains { $0.hidden } && !up.moods.contains { $0.hidden } && !up.formats.contains { $0.id == lyric.id },
                      "Kein Ausblenden mehr: Einträge sind da oder gelöscht")
            try check(changed && !vis.contains(warm.id) && vis.contains(roh.id) && vis.contains(eigen.id)
                      && up.formats.contains { $0.name == "Splitscreen" } && !up.upgradeDefaults(usedMoodIDs: []),
                      "Alte Mediathek: ungenutzte alte Moods ausgeblendet, Splitscreen ergänzt")
        }
        let song = cat.songNamed("Test Song / Nacht")
        let song2 = cat.songNamed("Zweiter")
        let zoomOut = cat.formats.first { $0.name == "Zoom-out" }!
        let stutter = cat.formats.first { $0.name == "Stutter" }!
        let ruhig = cat.moods.first { $0.name == "ruhig" }!
        let dunkel = cat.moods.first { $0.name == "dunkel" }!
        let energie = cat.moods.first { $0.name == "energetisch" }!
        try await lib.setCatalog(cat)
        try check(cat.songNamed("test song / NACHT").id == song.id, "Song-Schreibweise läuft nicht auseinander")

        print("Song-Audio")
        let wav1 = src.appendingPathComponent("Nachtfahrt Mix 1.wav")
        let wav2 = src.appendingPathComponent("Nachtfahrt Mix 2.wav")
        try Data(repeating: 1, count: 4096).write(to: wav1)
        try Data(repeating: 2, count: 4096).write(to: wav2)
        let neu = try await lib.addSongAudio(to: nil, title: "Audio Song", from: wav1, duration: nil)
        try check(neu.versions.count == 1 && neu.current?.number == 1 && neu.current!.file.hasPrefix("Songs/Audio-Song_")
                  && fm.fileExists(atPath: lib.paths.url(neu.current!.file).path), "Neuer Song mit Audio unter Songs/ (\(neu.current?.file ?? "-"))")
        do { _ = try await lib.addSongAudio(to: neu.id, title: "", from: wav1, duration: nil); throw Fail("doppelte Audiodatei angenommen") }
        catch is FileOps.Failure {}
        let zwei = try await lib.addSongAudio(to: neu.id, title: "", from: wav2, duration: nil)
        try check(zwei.versions.count == 2 && zwei.current?.number == 2 && zwei.id == neu.id
                  && fm.fileExists(atPath: lib.paths.url(zwei.current!.file).deletingLastPathComponent().appendingPathComponent(SongAudio.sidecarName).path),
                  "Neue Version wird aktuell, Begleitdatei liegt daneben")
        try check(try FileOps.sha256(wav1) == zwei.versions[0].sha256, "Original bleibt unverändert")
        do { _ = try await lib.addSongAudio(to: nil, title: "audio song", from: wav2, duration: nil); throw Fail("Song doppelt angelegt") }
        catch is FileOps.Failure {}
        let geteilt = try await lib.addSongAudio(to: nil, title: "Zweiter Song gleiche Datei", from: wav1, duration: nil)
        try check(geteilt.versions.count == 1 && geteilt.id != neu.id, "Dieselbe Audiodatei darf bei mehreren Songs liegen")
        let wellen = src.appendingPathComponent("wellenform.wav")
        try Screenshots.silentWAV(seconds: 3, seed: 1).write(to: wellen)
        let peaks = Waveform.compute(wellen, bars: 60)
        print("Wellenform: \(peaks.prefix(12).map { String(format: "%.2f", $0) }.joined(separator: " "))")
        try check(peaks.count == 60 && (peaks.max() ?? 0) > 0.99 && (peaks.min() ?? 1) < 0.8, "Wellenform aus Audiodatei")
        var restored = Catalog.makeDefault()
        SongAudio.absorbSidecars(into: &restored, paths: lib.paths)
        try check(restored.song(neu.id)?.versions.count == 2, "Songs mit Audio lassen sich aus den Begleitdateien zurückholen")
        try check(Attrs.differing([Attrs(kindID: "a", songIDs: ["x"]), Attrs(kindID: "a", songIDs: ["y"], moodIDs: ["m"])]) == ["Song", "Mood"],
                  "Import erkennt abweichende Angaben")
        cat = await lib.currentCatalog()

        print("Import")
        let a1 = Attrs(kindID: Naming.guessKind(v1.lastPathComponent), songIDs: [song.id], formatID: zoomOut.id,
                       moodIDs: [ruhig.id], description: "Abendlicht am Fenster", tags: ["Balkon"])
        try check(a1.kindID == Kind.raw, "Faustregel: IMG_ = RAW")
        try check(Naming.guessKind(v2.lastPathComponent) == Kind.final, "Faustregel: final/export = FINAL")
        guard case .imported(let r1) = try await Importer.importFile(v1, sha: nil, attrs: a1, into: lib) else { throw Fail("Import 1") }
        try check(r1.relPath.hasPrefix("Material/2025/2025-03/2025-03-07/"), "Ablage nach Entstehungstag aus Metadaten (\(r1.relPath))")
        try check(r1.createdAtSource == "metadata", "Entstehungsdatum aus den Video-Metadaten")
        var tagCat = cat
        tagCat.tags = []
        tagCat.noteTags(["Sommer"])
        var tagRec = r1
        tagRec.tags = ["Bühne", "sommer"]
        try check(tagCat.allTags([tagRec]) == ["Sommer", "Bühne"], "Tags-Seite zeigt angelegte und an Videos hinterlegte Tags")
        try check(r1.file.hasPrefix("2025-03-07_") && r1.file.contains("_RAW_Test-Song-Nacht_") && r1.file.hasSuffix(".mov"),
                  "Dateiname Datum_Uhrzeit_Art_Song_ID (\(r1.file))")
        let side1 = Sidecar.url(forVideo: lib.paths.url(r1.relPath))
        try check(fm.fileExists(atPath: side1.path), "Begleitdatei liegt neben dem Video")
        let read1 = try Sidecar.read(side1)
        try check(read1.songs.first?.title == "Test Song / Nacht" && read1.format.name == "Zoom-out" && read1.moods.map(\.name) == ["ruhig"],
                  "Begleitdatei hat IDs und Klartext")
        try check(read1.source?["loomnTake"]?["session"]?["id"]?.string == "TEST-SESSION", "Loomn-Cam-Metadaten für später aufbewahrt")
        try check(try FileOps.sha256(lib.paths.url(r1.relPath)) == v1sha, "Kopie identisch mit dem Original")
        try check(fm.fileExists(atPath: v1.path) && (try FileOps.sha256(v1)) == v1sha
                  && (try v1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == v1mod,
                  "Original unverändert")

        let a2 = Attrs(kindID: Naming.guessKind(v2.lastPathComponent), songIDs: [], formatID: stutter.id, moodIDs: [energie.id, dunkel.id])
        guard case .imported(let r2) = try await Importer.importFile(v2, sha: nil, attrs: a2, into: lib) else { throw Fail("Import 2") }
        try check(r2.file.contains("_FINAL_ohne-Song_") && r2.file.hasSuffix(".mp4"), "ohne Song im Namen (\(r2.file))")
        let a3 = Attrs(kindID: Kind.raw, songIDs: [song.id, song2.id], formatID: zoomOut.id, moodIDs: [ruhig.id, dunkel.id], tags: ["Nacht"])
        guard case .imported(let r3) = try await Importer.importFile(v3, sha: nil, attrs: a3, into: lib) else { throw Fail("Import 3") }
        try check(r3.relPath.hasPrefix("Material/2024/2024-12/2024-12-31/"), "Jahreswechsel richtig abgelegt")
        try check(r3.songs.count == 2, "Mehrere Songs pro Video")
        try check(!Attrs(kindID: Kind.raw, songIDs: [], formatID: zoomOut.id, moodIDs: [ruhig.id]).complete, "Song ist Pflicht")
        try check(a1.complete && !Attrs(kindID: Kind.raw, songIDs: nil, formatID: zoomOut.id, moodIDs: [ruhig.id]).complete,
                  "Pflichtangaben werden geprüft")

        print("Duplikate")
        guard case .duplicate(let d1) = try await Importer.importFile(v1, sha: nil, attrs: a1, into: lib), d1 == r1.id else { throw Fail("Duplikat nicht erkannt") }
        let copy = src.appendingPathComponent("anderer Name.mov")
        try fm.copyItem(at: v1, to: copy)
        guard case .duplicate = try await Importer.importFile(copy, sha: nil, attrs: a1, into: lib) else { throw Fail("Umbenanntes Duplikat nicht erkannt") }
        try check(await lib.count() == 3, "Duplikate werden nicht doppelt gespeichert")
        // gleichzeitiger Import derselben Datei
        async let p1 = Importer.importFile(v4, sha: nil, attrs: a1, into: lib)
        async let p2 = Importer.importFile(v4, sha: nil, attrs: a1, into: lib)
        let both = try await [p1, p2]
        let imported = both.filter { if case .imported = $0 { return true }; return false }.count
        let n4 = await lib.count()
        try check(imported == 1 && n4 == 4, "Doppelte im selben Stapel nur einmal")
        let r4 = both.compactMap { if case .imported(let r) = $0 { return r }; return nil }[0]
        try check(r4.relPath.hasPrefix("Material/2025/2025-03/2025-03-07/") && r4.file != r1.file, "Zwei Videos am selben Tag")

        print("Suche")
        var all = try await lib.allRecords()
        var f = LibraryFilter()
        f.songIDs = [song.id]; f.kindIDs = [Kind.raw]; f.formatIDs = [zoomOut.id]; f.moodIDs = [ruhig.id]
        try check(Set(f.apply(all).map(\.id)) == [r1.id, r3.id, r4.id], "Song + RAW + Zoom-out + ruhig")
        f.moodIDs = [ruhig.id, dunkel.id]
        try check(f.apply(all).map(\.id) == [r3.id], "Mehrere Moods = alle müssen passen")
        f = LibraryFilter(); f.noSong = true
        try check(f.apply(all).map(\.id) == [r2.id], "Filter „ohne Song“")
        f = LibraryFilter(); f.text = "abendlicht balkon"
        try check(Set(f.apply(all).map(\.id)) == [r1.id, r4.id], "Freitext über Beschreibung und Tags")
        f = LibraryFilter(); f.tags = ["nacht"]
        try check(f.apply(all).map(\.id) == [r3.id], "Tag-Filter")
        f = LibraryFilter(); f.from = Sidecar.parseDate("2025-01-01T12:00:00Z"); f.to = Sidecar.parseDate("2025-03-07T12:00:00Z")
        try check(Set(f.apply(all).map(\.id)) == [r1.id, r4.id], "Zeitraum")

        print("Bearbeiten")
        let side2 = Sidecar.url(forVideo: lib.paths.url(r2.relPath))
        var raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: side2))
        raw["zukunftsfeld"] = .string("bleibt")
        try JSONEncoder().encode(raw).write(to: side2)
        var e2 = r2
        Attrs(kindID: Kind.edit, songIDs: [song2.id], formatID: stutter.id, moodIDs: [energie.id], notes: "Version 2").apply(to: &e2, catalog: cat)
        let u2 = try await lib.update([e2])[0]
        try check(u2.file.contains("_EDIT_Zweiter_") && u2.file.hasPrefix(String(r2.file.prefix(15))), "Umbenannt nach Art und Song (\(u2.file))")
        try check(!fm.fileExists(atPath: lib.paths.url(r2.relPath).path) && fm.fileExists(atPath: lib.paths.url(u2.relPath).path), "Video mitverschoben")
        let side2b = Sidecar.url(forVideo: lib.paths.url(u2.relPath))
        raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: side2b))
        try check(raw["zukunftsfeld"]?.string == "bleibt", "Unbekannte Felder bleiben erhalten")
        try check((try Sidecar.read(side2b)).notes == "Version 2", "Begleitdatei aktualisiert")

        print("Listen umbenennen")
        cat = await lib.currentCatalog()
        let zi = cat.formats.firstIndex { $0.id == zoomOut.id }!
        cat.formats[zi].name = "Zoom-out weit"
        try await lib.setCatalog(cat)
        all = try await lib.allRecords()
        try check(all.first { $0.id == r1.id }?.format.name == "Zoom-out weit", "Neuer Anzeigename, gleiche Zuordnung")
        try check(fm.fileExists(atPath: lib.paths.url(r1.relPath).path), "Dateien nicht umbenannt")
        cat.formats[zi].hidden = true
        try await lib.setCatalog(cat)
        let stillThere = try await lib.allRecords().contains { $0.format.id == zoomOut.id }
        try check(!cat.visibleFormats.contains { $0.id == zoomOut.id } && stillThere,
                  "Ausblenden lässt alte Videos unberührt")
        cat.formats[zi].hidden = false
        try await lib.setCatalog(cat)

        print("Vorschauen")
        try await Previews.generate(video: lib.paths.url(r1.relPath), id: r1.id, into: [lib.paths.previews])
        try check(Previews.exists(r1.id, in: lib.paths.previews)
                  && fm.fileExists(atPath: lib.paths.previews.appendingPathComponent(Previews.stripPath(r1.id)).path), "Standbild und Bildreihe")

        print("Tool-Schnittstelle")
        let markiert = lib.paths.url(r1.relPath)
        LoomnArchiv.markiere(markiert, archivID: r1.id, song: "Nachtfahrt")
        try check(LoomnArchiv.archivID(von: markiert) == r1.id && LoomnArchiv.song(von: markiert) == "Nachtfahrt",
                  "Video trägt Archiv-ID und Song")
        let kopie = dir.appendingPathComponent("gezogen.mov")
        try fm.copyItem(at: markiert, to: kopie)
        try check(LoomnArchiv.archivID(von: kopie) == r1.id, "Markierung reist beim Kopieren mit")
        let zukunft = #"{"schnittstelle":2,"id":"x","werkzeug":"Loomn Beat","erstellt":"2026-10-19T12:00:00Z","datei":"a.mov","groesse":5,"art":"FINAL","song":"Nachtfahrt","neuesFeld":true}"#
        let gelesen = try LoomnArchiv.decoder.decode(LoomnArchiv.Lieferung.self, from: Data(zukunft.utf8))
        try check(gelesen.art == "FINAL" && gelesen.formate == nil, "Lieferung einer neueren Version wird gelesen")

        print("Index neu aufbauen")
        let root = lib.paths.root
        lib = try Library.open(root) // Index gesund: wird einfach geöffnet
        try check(await lib.count() == 4, "Mediathek wieder geöffnet")
        try fm.removeItem(at: lib.paths.index)
        lib = try Library.open(root)
        try check(await lib.count() == 4, "Fehlender Index aus Begleitdateien neu gebaut")
        try Data("kaputt".utf8).write(to: lib.paths.index)
        lib = try Library.open(root)
        try check(await lib.count() == 4, "Beschädigter Index ersetzt")
        try check(((try? fm.contentsOfDirectory(atPath: lib.paths.backups.path)) ?? []).contains { $0.hasPrefix("index-") },
                  "Beschädigter Index gesichert")
        try fm.removeItem(at: lib.paths.catalog)
        try fm.removeItem(at: lib.paths.index)
        lib = try Library.open(root)
        cat = await lib.currentCatalog()
        try check(cat.song(song.id)?.title == "Test Song / Nacht" && cat.format(zoomOut.id) != nil && cat.mood(dunkel.id)?.name == "dunkel",
                  "Verlorener Katalog aus Begleitdateien ergänzt")
        try check(await lib.count() == 4, "Alle Videos wieder da")

        print("Offline-Kopie")
        OfflineCache.save(lib.paths, id: libID)
        guard let off = OfflineCache.load(id: libID) else { throw Fail("Offline-Kopie fehlt") }
        try check(off.2.count == 4 && off.0.id == libID, "Ohne SSD blätterbar")
        try? fm.removeItem(at: Previews.cacheRoot(libraryID: libID))

        print("Umzug: SSD an anderem Pfad")
        let ssdB = dir.appendingPathComponent("SSD-B/Woanders", isDirectory: true)
        try fm.createDirectory(at: ssdB, withIntermediateDirectories: true)
        let moved = ssdB.appendingPathComponent(root.lastPathComponent)
        try fm.moveItem(at: root, to: moved)
        guard let found = Locator.find(id: libID, hint: root, extra: [dir.appendingPathComponent("SSD-B")]) else { throw Fail("Mediathek nicht gefunden") }
        try check(found.standardizedFileURL.path == moved.standardizedFileURL.path, "Mediathek über ihre Kennung gefunden")
        lib = try Library.open(found)
        all = try await lib.allRecords()
        try check(all.count == 4 && all.allSatisfy { fm.fileExists(atPath: lib.paths.url($0.relPath).path) }, "Alles da, ohne Videos zu kopieren")

        print("Mediathek an neuen Ort kopieren")
        let ssdC = dir.appendingPathComponent("SSD-C", isDirectory: true)
        try fm.createDirectory(at: ssdC, withIntermediateDirectories: true)
        let copied = try Relocation.copyLibrary(from: found, toParent: ssdC) { _, _ in }
        let libC = try Library.open(copied)
        let cID = await libC.id, cN = await libC.count()
        try check(cID == libID && cN == 4, "Kopie vollständig und geprüft")

        print("Versionsschutz")
        var m = try Library.readManifest(copied)
        m.schema = Manifest.schemaVersion + 1
        try Sidecar.encoder.encode(m).write(to: copied.appendingPathComponent(Manifest.fileName))
        do {
            _ = try Library.open(copied)
            throw Fail("Neuere Mediathek wurde geöffnet")
        } catch LibraryError.newer {
            print("  ✓ Neuere Mediathek wird nicht verändert")
        }
        m.schema = 0
        try Sidecar.encoder.encode(m).write(to: copied.appendingPathComponent(Manifest.fileName))
        let up = try Library.open(copied)
        let upN = await up.count()
        try check((try Library.readManifest(copied)).schema == Manifest.schemaVersion && upN == 4, "Ältere Mediathek angehoben")
        try check(((try? fm.contentsOfDirectory(atPath: up.paths.backups.path)) ?? []).contains { $0.contains("vor-anhebung") },
                  "Sicherung vor dem Anheben")

        try await lidar(dir)
        try await exportNachArchivn(dir)
    }

    /// „Export direkt nach archivn“: Annahme nur aus `An archivn`, Zuordnung von Song und Ausgangsclips,
    /// Übernahme als EDIT, Video und Begleitdatei danach im Übergabe-Ordner weg, Antwort-JSON.
    static func exportNachArchivn(_ dir: URL) async throws {
        print("Export nach archivn")
        let fm = FileManager.default
        let ssd = dir.appendingPathComponent("SSD-E", isDirectory: true)
        let fremd = dir.appendingPathComponent("Downloads", isDirectory: true)
        let an = dir.appendingPathComponent("editn/\(ExportAnnahme.ordnerName)", isDirectory: true)
        try fm.createDirectory(at: ssd, withIntermediateDirectories: true)
        try fm.createDirectory(at: fremd, withIntermediateDirectories: true)
        try fm.createDirectory(at: an, withIntermediateDirectories: true)
        let lib = try Library.create(in: ssd)
        var cat = await lib.currentCatalog()
        let song = cat.songNamed("Nachtfahrt")
        let zoomOut = cat.formats.first { $0.name == "Zoom-out" }!
        let ruhig = cat.moods.first { $0.name == "ruhig" }!
        try await lib.setCatalog(cat)

        // Ausgangsclip im Archiv
        let clip = fremd.appendingPathComponent("IMG_0412.MOV")
        try await makeVideo(clip, hue: 0.2, creation: "2026-11-01T10:00:00+01:00", loomnTake: false)
        guard case .imported(let quelle) = try await Importer.importFile(
            clip, sha: nil, attrs: Attrs(kindID: Kind.raw, songIDs: [song.id], formatID: zoomOut.id, moodIDs: [ruhig.id], tags: ["Sommer"]),
            into: lib) else { throw Fail("Ausgangsclip") }

        // Export von editn
        let name = "Sommer Edit 2026-11-07 18-30.mp4"
        let video = an.appendingPathComponent(name)
        try await makeVideo(video, hue: 0.7, creation: nil, loomnTake: false, type: .mp4)
        let json = #"{"loomnExport":1,"tool":"moshn","toolName":"editn","toolBuild":102,"erstellt":"2026-11-07T18:30:12+01:00","datei":"\#(name)","titel":"Sommer Edit","projekt":{"name":"Sommer Edit","pfad":"/x/Sommer Edit.beatmosh"},"video":{"breite":320,"hoehe":180,"format":"16:9","dauer":2,"fps":10,"ton":false,"codec":"h264"},"bereich":null,"song":{"name":"track.mp3","pfad":"/gibt/es/nicht.mp3","archivId":"Nachtfahrt · LION","bpm":124},"quellen":[{"name":"IMG_0412.MOV","pfad":"/x/IMG_0412.MOV","archivId":"\#(quelle.id)"}],"rueckweg":"\#(an.path)/","neuesFeld":true}"#
        try Data(json.utf8).write(to: ExportAnnahme.begleitdatei(zu: video))

        // Abgelehnt: falscher Ordner, fehlende oder fremde Begleitdatei
        let draussen = fremd.appendingPathComponent(name)
        try fm.copyItem(at: video, to: draussen)
        try fm.copyItem(at: ExportAnnahme.begleitdatei(zu: video), to: ExportAnnahme.begleitdatei(zu: draussen))
        try check((try? ExportAnnahme.pruefe(draussen)) == nil, "Export außerhalb von „An archivn“ abgelehnt")
        let ohne = an.appendingPathComponent("ohne Begleitdatei.mp4")
        try fm.copyItem(at: video, to: ohne)
        try check((try? ExportAnnahme.pruefe(ohne)) == nil, "Export ohne Begleitdatei abgelehnt")
        let falsch = an.appendingPathComponent("anderer Name.mp4")
        try fm.copyItem(at: video, to: falsch)
        try fm.copyItem(at: ExportAnnahme.begleitdatei(zu: video), to: ExportAnnahme.begleitdatei(zu: falsch))
        try check((try? ExportAnnahme.pruefe(falsch)) == nil, "Begleitdatei einer anderen Datei abgelehnt")

        let fund = try ExportAnnahme.pruefe(video)
        try check(fund.begleitung.toolName == "editn" && fund.roh["neuesFeld"] != nil, "Begleitdatei gelesen, unbekannte Felder bleiben")
        try check(ExportAnnahme.empfaenger(fund.begleitung) == "com.loomn.beatmosh", "Antwort geht an editn")
        try check(ExportAnnahme.liegengeblieben(in: [an], alter: 0).map(\.lastPathComponent).contains(name),
                  "Liegengebliebener Export wird gefunden")

        // Zuordnung
        cat = await lib.currentCatalog()
        let all = try await lib.allRecords()
        let plan = ExportAnnahme.plan(fund.begleitung, catalog: cat, records: all, attribut: { _, _ in nil })
        try check(plan.songID == song.id, "Song aus der Archiv-Markierung („Nachtfahrt · LION“)")
        try check(plan.herkunft == [quelle.id] && plan.formatID == zoomOut.id && plan.moodIDs == [ruhig.id] && plan.tags == ["Sommer"],
                  "Format, Mood und Tags vom Ausgangsclip")
        try check(plan.beschreibung == "Sommer Edit" && plan.projekt == "Sommer Edit", "Titel und Projekt")
        var ohneSong = fund.begleitung
        ohneSong.song = nil
        try check(ExportAnnahme.plan(ohneSong, catalog: cat, records: all, attribut: { _, _ in nil }).songID == song.id,
                  "Ohne Song: Song der Ausgangsclips")

        // Übernahme
        var a = Attrs()
        a.kindID = Kind.edit
        a.songIDs = plan.songID.map { [$0] } ?? []
        a.formatID = plan.formatID
        a.moodIDs = plan.moodIDs
        a.tags = plan.tags
        a.description = plan.beschreibung
        let (id, ort) = try await ExportAnnahme.uebernimm(fund, attrs: a, projekt: Ref(id: "p1", name: "Sommer Edit"),
                                                          herkunft: plan.herkunft, into: lib)
        guard let neu = try await lib.allRecords().first(where: { $0.id == id }) else { throw Fail("Export nicht im Archiv") }
        try check(neu.kind.id == Kind.edit && neu.songs.first?.id == song.id && neu.project?.name == "Sommer Edit"
                  && neu.description == "Sommer Edit", "Export als EDIT mit Song und Projekt im Archiv")
        try check(neu.source?["herkunft"] == .array([.string(quelle.id)]) && neu.source?["werkzeug"]?.string == "editn",
                  "Herkunft und Tool vermerkt")
        try check(fm.fileExists(atPath: ort.path) && !fm.fileExists(atPath: video.path)
                  && !fm.fileExists(atPath: ExportAnnahme.begleitdatei(zu: video).path), "Verschoben: im Übergabe-Ordner nichts mehr")
        let antwort = ExportAnnahme.antwortJSON(datei: name, ok: true, id: id, ort: ort)
        let gelesen = try JSONSerialization.jsonObject(with: Data(antwort.utf8)) as? [String: Any]
        try check(gelesen?["ok"] as? Bool == true && gelesen?["id"] as? String == id && gelesen?["loomnExport"] as? Int == 1,
                  "Antwort-JSON")
    }

    // MARK: LiDAR (Tiefen-Takes aus Loomn Cam)

    /// Eine Loomn-Box wie Loomn Cam 0.26 sie hinter die .mov hängt.
    static func loomnBox(_ kind: String, _ body: Data) -> Data {
        var d = Data([0, 0, 0, 1]) + Data("uuid".utf8)
        var size = UInt64(40 + body.count).bigEndian
        d += Data(bytes: &size, count: 8)
        d += Data(LoomnDepth.uuid)
        var k = Data(kind.utf8)
        k += Data(repeating: 0, count: 8 - k.count)
        return d + k + body
    }

    /// LDEP-Kopf: „LDEP“, Version, Breite, Höhe (Little Endian), dann Tiefendaten
    static func ldep(_ w: Int, _ h: Int) -> Data {
        var d = Data("LDEP".utf8)
        for v in [1, w, h] { d += Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
        return d + Data(repeating: 7, count: 512)
    }

    static func append(_ data: Data, to url: URL) throws {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: data)
    }

    static func lidar(_ dir: URL) async throws {
        print("LiDAR")
        let fm = FileManager.default
        let src = dir.appendingPathComponent("AirDrop", isDirectory: true)
        let ssd = dir.appendingPathComponent("SSD-L", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: ssd, withIntermediateDirectories: true)
        func take(_ id: String) -> String {
            #"{"format":"loomn.take","version":1,"takeId":"\#(id)","kind":"depth","run":"2026-11-07T17:15:00+01:00","depth":{"source":"lidar","width":256,"height":192,"lossless":{"container":"uuid-box","uuid":"6C6F6F6D-6E2D-7369-6465-636172000001","kind":"ldepth","format":"LDEP v1"}}}"#
        }

        // Neu (0.26): alles in einer .mov
        let neu = src.appendingPathComponent("Loomn_2026-11-07_1715_Tiefe.mov")
        try await makeVideo(neu, hue: 0.1, creation: "2026-11-07T17:15:00+01:00", loomnTake: false, take: take("TAKE-NEU"))
        try append(loomnBox("ldepth", ldep(256, 192)) + loomnBox("obj", Data("v 0 0 0\n".utf8)) + loomnBox("zukunft", Data([1, 2, 3])), to: neu)
        let neuSHA = try FileOps.sha256(neu)
        let scan = LoomnDepth.scan(neu)
        try check(scan.hasLossless && scan.depthWidth == 256 && scan.depthHeight == 192 && scan.kinds == ["ldepth", "obj", "zukunft"],
                  "Loomn-Box ldepth in der .mov gefunden (256×192), unbekannte Art stört nicht")
        let probeTake = await Probe.take(neu)
        let info = LoomnDepth.inspect(neu, take: probeTake)
        try check(info?.state == .lossless && info?.takeId == "TAKE-NEU", "Merkmal „Tiefe verlustfrei“, takeId gelesen")
        let neuProbe = await Probe.load(neu)
        try check(neuProbe.media.width == 320, "Video mit Boxen am Ende spielt normal (AVFoundation liest es)")

        // Ohne Box (z. B. über Fotos/iCloud gekommen): nur Videospur, kein Fehler
        let ohne = src.appendingPathComponent("Loomn_2026-11-07_1716_Tiefe.mov")
        try await makeVideo(ohne, hue: 0.2, creation: "2026-11-07T17:16:00+01:00", loomnTake: false, take: take("TAKE-OHNE"))
        let ohneTake = await Probe.take(ohne)
        try check(LoomnDepth.inspect(ohne, take: ohneTake)?.state == .videoOnly, "Ohne Box und ohne .ldepth: „nur Videospur“")

        // Abgeschnittene Box: kein Absturz, „Tiefe beschädigt“
        let kaputt = src.appendingPathComponent("Loomn_2026-11-07_1717_Tiefe.mov")
        try fm.copyItem(at: neu, to: kaputt)
        let full = try Data(contentsOf: kaputt)
        let cut = full.count - 600
        try full.prefix(cut).write(to: kaputt)
        try check(LoomnDepth.inspect(kaputt, take: nil)?.state == .damaged, "Abgeschnittene Box: „Tiefe beschädigt“, kein Absturz")
        try Data([0, 0, 0, 1]).write(to: src.appendingPathComponent("muell.mov"))
        try check(LoomnDepth.scan(src.appendingPathComponent("muell.mov")).boxes.isEmpty, "Unsinnige Datei: kein Absturz")

        // Normale Videos sind kein LiDAR
        let normal = src.appendingPathComponent("IMG_9000.mov")
        try await makeVideo(normal, hue: 0.4, creation: nil, loomnTake: true)
        let normalTake = await Probe.take(normal)
        try check(LoomnDepth.inspect(normal, take: normalTake) == nil, "Normales Video ist kein LiDAR-Clip")

        // Alter Take (vor 0.26): .mov mit .ldepth/.obj daneben
        let alt = src.appendingPathComponent("Loomn_2026-10-01_1200_Tiefe.mov")
        try await makeVideo(alt, hue: 0.5, creation: "2026-10-01T12:00:00+02:00", loomnTake: false, take: take("TAKE-ALT"))
        try ldep(256, 192).write(to: alt.deletingPathExtension().appendingPathExtension("ldepth"))
        try Data("v 1 1 1\n".utf8).write(to: alt.deletingPathExtension().appendingPathExtension("obj"))
        let altTake = await Probe.take(alt)
        try check(LoomnDepth.inspect(alt, take: altTake)?.state == .sidecar, "Alter Take: .ldepth daneben erkannt")
        // Beides: Box in der .mov und Datei daneben
        try ldep(256, 192).write(to: neu.deletingPathExtension().appendingPathExtension("ldepth"))
        try check(LoomnDepth.inspect(neu, take: nil)?.redundant == ["ldepth"], "Box und .ldepth daneben: Datei als überzählig gemeldet")
        try fm.removeItem(at: neu.deletingPathExtension().appendingPathExtension("ldepth"))

        // Tiefen-Paket desselben Takes
        let paket = src.appendingPathComponent("Loomn_2026-11-07_1715_Tiefen-Paket.zip")
        let stage = dir.appendingPathComponent("paket", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data(take("TAKE-NEU").utf8).write(to: stage.appendingPathComponent("take.json"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = stage
        zip.arguments = ["-q", "-r", paket.path, "."]
        try zip.run(); zip.waitUntilExit()
        let found = FileOps.collectVideos([src])
        try check(found.contains { $0.lastPathComponent == paket.lastPathComponent } && found.allSatisfy { !["ldepth", "obj"].contains($0.pathExtension) },
                  "Tiefen-Paket wird angeboten, Begleitdateien nicht einzeln")
        let pinfo = LoomnDepth.inspect(paket, take: nil)
        try check(pinfo?.state == .package && pinfo?.takeId == "TAKE-NEU", "takeId aus take.json im Paket")

        print("LiDAR importieren")
        let lib = try Library.create(in: ssd)
        var cat = await lib.currentCatalog()
        let song = cat.songNamed("Tiefe")
        try await lib.setCatalog(cat)
        cat = await lib.currentCatalog()
        let a = Attrs(kindID: Kind.raw, songIDs: [song.id], formatID: cat.formats[0].id, moodIDs: [cat.moods[0].id])
        guard case .imported(let r) = try await Importer.importFile(neu, sha: nil, attrs: a, into: lib) else { throw Fail("LiDAR-Import") }
        let copy = lib.paths.url(r.relPath)
        try check(try FileOps.sha256(copy) == neuSHA && FileOps.size(copy) == FileOps.size(neu) && r.sha256 == neuSHA,
                  "Kopie Byte für Byte gleich, Fingerabdruck über die ganze Datei (mit Boxen)")
        try check(try FileOps.sha256(neu) == neuSHA, "Original unverändert")
        try check(LoomnDepth.scan(copy).hasLossless, "Tiefe steckt auch in der Kopie")
        let side = try Sidecar.read(Sidecar.url(forVideo: copy))
        try check(side.isLiDAR && side.depth?.state == .lossless && side.depth?.width == 256 && side.depth?.companions.isEmpty == true
                  && side.kind.id == Kind.raw, "Begleitdatei: RAW mit LiDAR, Tiefe verlustfrei, keine Begleitdateien")

        guard case .imported(let ra) = try await Importer.importFile(alt, sha: nil, attrs: a, into: lib) else { throw Fail("Alter Take") }
        let altCopy = lib.paths.url(ra.relPath)
        let base = altCopy.deletingPathExtension()
        try check(ra.depth?.state == .sidecar && ra.depth?.companions.map(\.ext) == ["ldepth", "obj"]
                  && fm.fileExists(atPath: base.appendingPathExtension("ldepth").path) && fm.fileExists(atPath: base.appendingPathExtension("obj").path),
                  "Alter Take: Begleitdateien mitkopiert, gleicher Name wie das Video")
        try check(try FileOps.sha256(base.appendingPathExtension("ldepth")) == ra.depth?.companions.first?.sha256,
                  "Begleitdatei geprüft kopiert")
        var edited = ra
        let umbenannt = cat.songNamed("Umbenannt")
        try await lib.setCatalog(cat)
        edited.songs = [umbenannt.ref]
        let up = try await lib.update([edited])[0]
        let newBase = lib.paths.url(up.relPath).deletingPathExtension()
        try check(up.file != ra.file && fm.fileExists(atPath: newBase.appendingPathExtension("ldepth").path)
                  && !fm.fileExists(atPath: base.appendingPathExtension("ldepth").path)
                  && up.depth?.companions.first?.file == newBase.appendingPathExtension("ldepth").lastPathComponent,
                  "Umbenennen nimmt die Begleitdateien mit")

        // Gleiche Aufnahme: .mov und Paket
        let all = try await lib.allRecords()
        var draft = ImportDraft(urls: [paket], catalog: cat)
        draft.update(draft.items[0].id) { $0.depth = pinfo }
        draft.markSameTakes(archive: all)
        try check(draft.items[0].sameTake != nil && draft.importable.isEmpty, "Paket zur .mov im Archiv: gleiche Aufnahme, .mov bevorzugt")
        var filter = LibraryFilter()
        filter.lidarOnly = true
        let mixed = all + [{ var x = r; x.id = "normal"; x.source = nil; return x }()]
        try check(filter.apply(mixed).count == 2 && filter.apply(mixed).allSatisfy(\.isLiDAR), "LiDAR-Symbol zeigt nur LiDAR-Clips")
        filter.lidarOnly = false
        filter.kindIDs = [Kind.raw]
        try check(filter.apply(mixed).count == 3, "RAW zeigt alle, auch die LiDAR-Clips")
    }

    // MARK: Testvideos

    static func makeVideo(_ url: URL, hue: Double, creation: String?, loomnTake: Bool, type: AVFileType = .mov,
                          take: String? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let W = 320, H = 180, frames = 20
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        var meta: [AVMetadataItem] = []
        if let creation {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = creation as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            meta.append(item)
        }
        if loomnTake || take != nil {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = "de.loomn.take" as NSString
            item.value = (take ?? #"{"format":"loomn.take","version":1,"session":{"id":"TEST-SESSION","title":"Test"},"song":{"title":"Test Song / Nacht"}}"#) as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            meta.append(item)
        }
        writer.metadata = meta
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Fail("Testvideo") }
        writer.startSession(atSourceTime: .zero)
        let ctx = CIContext()
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Fail("Pool") }
            var px: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &px)
            guard let px else { throw Fail("Puffer") }
            let b = 0.3 + 0.5 * Double(i) / Double(frames)
            let color = CIColor(red: b * (1 - hue), green: b * hue, blue: b * 0.5)
            ctx.render(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: W, height: H)), to: px)
            adaptor.append(px, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Fail("Testvideo nicht geschrieben") }
    }
}
