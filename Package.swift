// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Autodoc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Autodoc",
            path: "Sources/Autodoc"
        ),
        .testTarget(
            name: "AutodocTests",
            dependencies: ["Autodoc"],
            path: "Tests"
        ),
    ]
)
