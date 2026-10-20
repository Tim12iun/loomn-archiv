# Loomn Archiv

## Tool-Schnittstelle (dauerhaft)

- `Sources/LoomnArchiv/LoomnArchivSchnittstelle.swift` ist in allen Loomn-Tools wortgleich. Nie nur hier ändern,
  nur über eine neue Fassung der Übergabe „Archiv-Schnittstelle“ für alle Tools gleichzeitig.
- Ordner- und Feldnamen nie umbenennen oder entfernen, nur neue optionale Felder ergänzen.
- Lieferungen aller älteren `schnittstelle`-Versionen weiter lesen.
- Archiv-Seite steht in `ArchivEingang.swift`: Katalog veröffentlichen, Eingang alle 5 s übernehmen
  (ohne Nachfrage), Quittung schreiben, Mediathek-Videos per Datei-Attribut mit ID und Song markieren.

## Andocken (dauerhaft)

- `Sources/LoomnArchiv/LoomnAndocken.swift` ist in allen Loomn-Tools wortgleich. Nie nur hier ändern.
- Nachrichten- und Feldnamen nie umbenennen oder entfernen, nur neue optionale Felder ergänzen.
- archivn-Seite (Fassung 2) steht in `CompanionDock.swift`: Nähe melden, `angedockt` erst nach der Andock-Animation, `geloest` erst nach dem Einsaugen ins Viereck, eigenes Fenster auf dem Ziel zum Herausziehen.

## Gestaltung (dauerhaft, Wunsch von LION)

- **Keine unnötigen Größenänderungen.** Elemente behalten ihre Größe, wenn eine Ansicht umgeschaltet wird
  (z. B. „Alle zeigen“ / „Als Reihe“, Vorschau auf/zu, Filter, Fenstergröße). Es ändert sich höchstens die Zahl
  der Spalten oder was sichtbar ist, nie die Kachel- oder Knopfgröße. Video-Kacheln im großen Fenster immer mit
  `VideoTile.width` bzw. `VideoTile.columns`.
- Keine Layout-Sprünge, Animationen ruhig und kurz; Orange heißt aktiv; gleiche Höhe für alle Bedienelemente.
- Verbindliche Design-Grundlage aller Loomn-Tools: `/mnt/project-files/Loomn Design Language/DESIGN-LANGUAGE.md`.

## Versionskopf in Übergaben (dauerhaft, Wunsch von LION)

- Jede Übergabe-MD an andere Loomn-Tools (Beatmosh/editn usw.) bekommt oben einen Kopf:
  `> **Stand: archivn Update <N> · LoomnAndocken Fassung <F> · setzt editn Build <B> voraus · <Datum>**`.
- Ersetzte Dateien oben mit **VERALTET … ersetzt durch …** markieren, nie stillschweigend liegen lassen.
- Fügt LION einen Text aus einem anderen Tool ein: dessen Kopf mit dem aktuellen Stand vergleichen. Ist er alt
  oder schon umgesetzt, LION darauf hinweisen statt es nochmal umzusetzen.
- Letzter bekannter Stand: archivn Update 148, LoomnAndocken Fassung 2, editn Build 60 (Übergabe editn Nr. 3, 20.10.2026; Teile 1–3 drin, Teil 4 „Startbildschirm“ noch offen).
