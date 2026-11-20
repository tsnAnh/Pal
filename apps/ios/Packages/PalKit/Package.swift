// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PalKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PalProtocol", targets: ["PalProtocol"]),
        .library(name: "PalDiagnostics", targets: ["PalDiagnostics"]),
        .library(name: "PalREST", targets: ["PalREST"]),
        .library(name: "PalAuth", targets: ["PalAuth"]),
        .library(name: "PalTransport", targets: ["PalTransport"]),
        .library(name: "PalPush", targets: ["PalPush"]),
        .library(name: "PalClient", targets: ["PalClient"]),
        .library(name: "PalChat", targets: ["PalChat"]),
        .library(name: "PalRoster", targets: ["PalRoster"]),
        .library(name: "PalBotProfile", targets: ["PalBotProfile"]),
        .library(name: "PalRFB", targets: ["PalRFB"]),
        .library(name: "PalDevice", targets: ["PalDevice"]),
        .library(name: "PalConnect", targets: ["PalConnect"]),
        .library(name: "PalSettings", targets: ["PalSettings"]),
        .library(name: "PalKanban", targets: ["PalKanban"]),
    ],
    targets: [
        .target(name: "PalProtocol", dependencies: ["PalDiagnostics"]),
        .target(name: "PalDiagnostics"),
        .target(name: "PalREST", dependencies: ["PalProtocol", "PalDiagnostics"]),
        .target(name: "PalAuth", dependencies: ["PalREST", "PalDiagnostics"]),
        .target(name: "PalTransport", dependencies: ["PalProtocol", "PalDiagnostics"]),
        .target(name: "PalPush"),
        .target(
            name: "PalClient",
            dependencies: ["PalProtocol", "PalDiagnostics", "PalREST", "PalAuth", "PalTransport", "PalPush"]
        ),
        .target(
            name: "PalChat",
            dependencies: [
                "PalProtocol", "PalDiagnostics", "PalTransport", "PalClient", "PalREST", "PalAuth",
            ]
        ),
        .target(name: "PalRoster", dependencies: ["PalProtocol", "PalDiagnostics", "PalTransport"]),
        .target(name: "PalBotProfile", dependencies: ["PalProtocol", "PalDiagnostics", "PalTransport", "PalRoster"]),
        .target(name: "PalRFB", dependencies: ["PalDiagnostics"]),
        .target(name: "PalDevice", dependencies: ["PalProtocol", "PalDiagnostics", "PalTransport"]),
        .target(
            name: "PalConnect",
            dependencies: ["PalProtocol", "PalDiagnostics", "PalTransport", "PalAuth"]
        ),
        .target(name: "PalSettings", dependencies: ["PalProtocol", "PalTransport"]),
        .target(name: "PalKanban", dependencies: ["PalProtocol", "PalTransport"]),
        .testTarget(
            name: "PalKitTests",
            dependencies: [
                "PalProtocol", "PalDiagnostics", "PalREST", "PalAuth", "PalTransport", "PalPush", "PalClient",
                "PalChat", "PalRoster", "PalBotProfile", "PalRFB", "PalDevice", "PalConnect", "PalSettings", "PalKanban",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
