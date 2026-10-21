// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LoomnEinklappen",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LoomnEinklappen", targets: ["LoomnEinklappen"])],
    targets: [
        .target(name: "LoomnEinklappen"),
        // Kleine Beispiel-App: `swift run Beispiel`
        .executableTarget(name: "Beispiel", dependencies: ["LoomnEinklappen"]),
    ]
)
