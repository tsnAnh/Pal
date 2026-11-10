// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HermesDesign",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "HermesDesign", targets: ["HermesDesign"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/SwiftDraw.git", .upToNextMinor(from: "0.29.0")),
    ],
    targets: [
        .target(
            name: "HermesDesign",
            dependencies: [.product(name: "SwiftDraw", package: "SwiftDraw")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HermesDesignTests",
            dependencies: ["HermesDesign"],
            resources: [.copy("Parity")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
