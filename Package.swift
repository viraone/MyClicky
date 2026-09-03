// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyClicky",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MyClicky", targets: ["MyClicky"])],
    targets: [
        .executableTarget(
            name: "MyClicky",
            path: "Sources/MyClicky",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
