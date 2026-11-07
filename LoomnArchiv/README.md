# Loomn Archiv

Mac-Werkzeug zum Aufheben, Sortieren und Wiederfinden von Video-Content (Rohvideos, Zwischenstände, fertige Reels). Videos per Drag-and-drop rein, kurz Art, Song, Format und Mood angeben, Enter. Das Werkzeug bearbeitet keine Videos, es speichert, sortiert und findet.

Voraussetzung: Mac mit Apple-Chip, macOS 14 (Sonoma) oder neuer. Läuft komplett offline (nur die Update-Prüfung fragt GitHub).

## Mediathek auf der SSD

Beim ersten Start: **Neue Mediathek anlegen** (Ort wählen, z. B. die externe SSD) oder **Vorhandene Mediathek öffnen**. Alles gehört in die Mediathek, auf dem Mac liegt nur die App:

```
Loomn Archiv/
  mediathek.loomn.json      Kennung (ID, Version)
  LIESMICH.txt
  Material/JJJJ/JJJJ-MM/JJJJ-MM-TT/
      2026-10-13_1502_RAW_Songname_8f3a.mov
      2026-10-13_1502_RAW_Songname_8f3a.loomn.json   Begleitdatei (die Wahrheit)
  Archivdaten/katalog.json  Arten, Formate, Moods, Songs, Tags, letzte Angaben
  Archivdaten/index.sqlite  Suchindex (neu erzeugbar)
  Archivdaten/Vorschauen/   Vorschaubilder (neu erzeugbar)
  Archivdaten/Sicherungen/  Kopien vor Umbauten
```

- Ablage nur nach Entstehungstag (Aufnahmedatum aus den Metadaten, sonst Erstelldatum der Datei). Art, Format, Song, Mood, Tags sind Angaben, keine Ordner, es wird also nie umsortiert.
- Jede Kopie wird per SHA-256 direkt von der Platte geprüft. Originale werden nie verändert.
- Duplikate (gleicher Fingerabdruck) werden erkannt und nicht doppelt gespeichert.
- Listen haben feste IDs: Umbenennen ändert nur die Anzeige, alte Videos behalten ihre Zuordnung.
- Begleitdateien enthalten IDs plus Klartext und eine Versionsnummer. Felder, die eine Version nicht kennt, bleiben beim Speichern erhalten. Metadaten aus Loomn Cam (`de.loomn.take`) werden unter `source.loomnTake` aufbewahrt, für die spätere Anbindung.
- Fehlt der Index oder ist er beschädigt, wird er aus den Begleitdateien neu gebaut. Fehlt der Katalog, wird er aus den Begleitdateien ergänzt. Ältere Mediatheken werden angehoben (vorher Sicherung), neuere werden nicht angerührt.
- Ohne SSD: Blättern und Suchen aus einer Kopie von Index und Vorschauen auf dem Mac (`~/Library/Caches/Loomn Archiv/`), Importieren erst mit SSD.

## LiDAR-Clips (Tiefen-Takes aus Loomn Cam)

- Erkannt über die Take-Beschreibung (`de.loomn.take`, `"kind": "depth"`) oder eine Loomn-Box in der Datei. LiDAR-Clips sind immer **RAW**; beim Import wird RAW automatisch gewählt. Neben dem RAW-Knopf (Bibliothek, Suche, Kompagnon) zeigt das LiDAR-Symbol nur die LiDAR-Clips, ohne es zeigt RAW alle.
- Ab Loomn Cam 0.26 steckt die Tiefe verlustfrei in der .mov (Loomn-Boxen `uuid`/„loomn-sidecar“ am Dateiende: `ldepth`, `obj`, `lmatte`). Merkmal in Liste und Details: „Tiefe verlustfrei“ (mit Auflösung aus dem `LDEP`-Kopf), sonst „nur Videospur (1 cm)“, bei kaputter Box „Tiefe beschädigt“. Angaben stehen in der Begleitdatei unter `source.loomnDepth`.
- Die .mov wird nur 1:1 kopiert, der Fingerabdruck geht über die ganze Datei. Nie remuxen, umkodieren oder Metadaten schreiben. Vorschauen sind nur Vorschau.
- Alte Takes: `.ldepth`, `.obj`, `.lmatte` daneben gehören zum selben Eintrag (geprüft mitkopiert, gleicher Name, wandern beim Umbenennen mit). Liegt der Inhalt auch als Box in der .mov, wird die Datei als überzählig gemeldet, nie gelöscht.
- `…_Tiefen-Paket.zip` wird angenommen (takeId aus `take.json`). Gleiche takeId wie eine .mov: dieselbe Aufnahme, das Paket wird im Importfenster abgewählt, die .mov bevorzugt.

## Umzug auf einen anderen Mac

App auf den neuen Mac ziehen, SSD anstecken, **Vorhandene Mediathek öffnen** und den Ordner wählen. Kein Video wird kopiert. Die App findet die Mediathek über ihre Kennung, auch unter einem anderen Pfad.

Umzug auf eine andere SSD: Einstellungen › Mediathek › **Umziehen …** kopiert alles mit Prüfung und arbeitet dann dort weiter.

## Updates

Jeder Build (außer Commits mit `[intern]`) wird als GitHub Release im öffentlichen Repo `Tim12iun/loomn-archiv` veröffentlicht (Tag `loomn-archiv-b<Build>`, Dateien `LoomnArchiv.zip` + `version.json`). Die App fragt beim Start und alle 30 Minuten nach, zeigt Version und Änderungen und installiert erst nach Klick auf **Aktualisieren** (Prüfsumme, Signatur und Bundle-ID werden geprüft, die alte Version landet im Papierkorb).

## Bauen

`scripts/build-app.sh` erzeugt `build/Loomn Archiv.app` und `build/LoomnArchiv.zip`. Der Workflow „Build Loomn Archiv (Mac)“ baut bei jedem Push, führt den Selbsttest aus (`LoomnArchiv --selftest <ordner>`), macht Bildschirmfotos der Oberfläche (`--screenshots <ordner>`), legt App und Bilder in den Zweig `loomn-archiv-app`, veröffentlicht das Release und prüft, dass es als Update ankommt (`--updatetest <build>`).

## Struktur

```
Sources/LoomnArchiv/
  Model.swift            Datensatz, Begleitdatei, Katalog, Angaben
  Library.swift          Mediathek anlegen/öffnen/anheben, Index-Neubau, Eintragen, Bearbeiten
  Index.swift            SQLite-Suchindex
  Importer.swift         Dateinamen, Fingerabdruck, geprüfte Kopie, Metadaten
  Tiefe.swift            LiDAR-Clips: Loomn-Boxen in der .mov, Begleitdateien, Tiefen-Paket
  Query.swift            Kombinierte Suche und Sortierung
  Locator.swift          Mediathek über ID finden, Offline-Kopie, Umzug
  Previews.swift         Standbild und Bildreihe für die Vorschau
  AppModel.swift         Zustand der App, Import-Warteschlange
  RootViews.swift        Fenster, Willkommen, Kopfzeile, SSD-Status
  LibraryViews.swift     Start, Bibliothek, Filter, Detailansicht
  ImportSheet.swift      Angaben beim Import
  AttributeEditor.swift  Art, Song, Format, Mood, Tags
  SettingsView.swift     Mediathek, Listen, Updates
  SelfTest.swift, Screenshots.swift
  Design.swift, Components.swift, LoomnLoader.swift, ToolUpdater.swift, UpdateBanner.swift
```
