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
    targets: [
        .target(
            name: "HermesDesign",
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
