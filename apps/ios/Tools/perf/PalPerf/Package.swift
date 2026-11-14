// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PalPerf",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../Packages/PalKit")],
    targets: [
        .executableTarget(
            name: "palperf",
            dependencies: [
                .product(name: "PalProtocol", package: "PalKit"),
                .product(name: "PalChat", package: "PalKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
