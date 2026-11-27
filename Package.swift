// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dockling",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dockling",
            path: "Sources/Dockling"
        ),
        .testTarget(
            name: "DocklingTests",
            dependencies: ["Dockling"],
            path: "Tests/DocklingTests"
        ),
    ]
)
