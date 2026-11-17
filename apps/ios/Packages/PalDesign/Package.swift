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
    targets: [
        .target(
            name: "PalDesign",
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
