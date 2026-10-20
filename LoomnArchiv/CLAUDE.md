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
- archivn-Seite steht in `CompanionDock.swift` (Quadrat auf Ziel ziehen, Fenster folgt, Lösen-Knopf oder Kopfzeile wegziehen).

## Gestaltung (dauerhaft, Wunsch von LION)

- **Keine unnötigen Größenänderungen.** Elemente behalten ihre Größe, wenn eine Ansicht umgeschaltet wird
  (z. B. „Alle zeigen“ / „Als Reihe“, Vorschau auf/zu, Filter, Fenstergröße). Es ändert sich höchstens die Zahl
  der Spalten oder was sichtbar ist, nie die Kachel- oder Knopfgröße. Video-Kacheln im großen Fenster immer mit
  `VideoTile.width` bzw. `VideoTile.columns`.
- Keine Layout-Sprünge, Animationen ruhig und kurz; Orange heißt aktiv; gleiche Höhe für alle Bedienelemente.
- Verbindliche Design-Grundlage aller Loomn-Tools: `/mnt/project-files/Loomn Design Language/DESIGN-LANGUAGE.md`.
