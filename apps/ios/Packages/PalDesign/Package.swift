// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PalDesign",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "PalDesign", targets: ["PalDesign"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/SwiftDraw.git", .upToNextMinor(from: "0.29.0")),
    ],
    targets: [
        .target(
            name: "PalDesign",
            dependencies: [.product(name: "SwiftDraw", package: "SwiftDraw")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalDesignTests",
            dependencies: ["PalDesign"],
            resources: [.copy("Parity")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
