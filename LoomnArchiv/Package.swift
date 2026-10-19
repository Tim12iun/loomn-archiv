// swift-tools-version:5.10
import PackageDescription

// Loomn Archiv: Mac-Werkzeug zum Sortieren, Aufheben und Wiederfinden von Video-Content.
// Bauen: scripts/build-app.sh (erzeugt LoomnArchiv.app). Zum Entwickeln Package.swift in Xcode öffnen.
let package = Package(
    name: "LoomnArchiv",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LoomnArchiv",
            path: "Sources/LoomnArchiv",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("AVKit"), .linkedFramework("AVFoundation")]
        ),
    ]
)
