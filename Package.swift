// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanerKit", targets: ["CleanerKit"]),
        .executable(name: "cleaner", targets: ["cleaner"]),
    ],
    dependencies: [
        // Kararlı sürüme sabit (exact). Güncelleme bilinçli yapılır.
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.1"),
    ],
    targets: [
        .target(
            name: "CleanerKit",
            resources: [.process("Resources/rules.json")]
        ),
        .executableTarget(
            name: "cleaner",
            dependencies: [
                "CleanerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CleanerKitTests",
            dependencies: ["CleanerKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
