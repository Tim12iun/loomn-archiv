# Loomn Archiv

## Tool-Schnittstelle (dauerhaft)

- `Sources/LoomnArchiv/LoomnArchivSchnittstelle.swift` ist in allen Loomn-Tools wortgleich. Nie nur hier ändern,
  nur über eine neue Fassung der Übergabe „Archiv-Schnittstelle“ für alle Tools gleichzeitig.
- Ordner- und Feldnamen nie umbenennen oder entfernen, nur neue optionale Felder ergänzen.
- Lieferungen aller älteren `schnittstelle`-Versionen weiter lesen.
- Archiv-Seite steht in `ArchivEingang.swift`: Katalog veröffentlichen, Eingang alle 5 s übernehmen
  (ohne Nachfrage), Quittung schreiben, Mediathek-Videos per Datei-Attribut mit ID und Song markieren.
