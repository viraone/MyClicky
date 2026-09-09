// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyClicky",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MyClicky", targets: ["MyClicky"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyClicky",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MyClicky",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MyClickyTests",
            dependencies: ["MyClicky"],
            path: "Tests/MyClickyTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
