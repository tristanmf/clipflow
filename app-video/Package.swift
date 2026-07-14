// swift-tools-version:5.9
// App macOS « Vidéo » — interface SwiftUI pour les outils de sous-titrage /
// extraction / compression de Tristan. Voir app-video/README.md.
import PackageDescription

let package = Package(
    name: "Video",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Video",
            path: "Sources/Video"
        )
    ]
)
