// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HermesKit",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "HermesProtocol", targets: ["HermesProtocol"]),
        .library(name: "HermesDiagnostics", targets: ["HermesDiagnostics"]),
        .library(name: "HermesREST", targets: ["HermesREST"]),
        .library(name: "HermesAuth", targets: ["HermesAuth"]),
        .library(name: "HermesTransport", targets: ["HermesTransport"]),
        .library(name: "HermesClient", targets: ["HermesClient"]),
        .library(name: "HermesChat", targets: ["HermesChat"]),
        .library(name: "HermesRoster", targets: ["HermesRoster"]),
        .library(name: "HermesBotProfile", targets: ["HermesBotProfile"]),
        .library(name: "HermesRFB", targets: ["HermesRFB"]),
        .library(name: "HermesDevice", targets: ["HermesDevice"]),
        .library(name: "HermesConnect", targets: ["HermesConnect"]),
    ],
    targets: [
        .target(name: "HermesProtocol", dependencies: ["HermesDiagnostics"]),
        .target(name: "HermesDiagnostics"),
        .target(name: "HermesREST", dependencies: ["HermesProtocol", "HermesDiagnostics"]),
        .target(name: "HermesAuth", dependencies: ["HermesREST", "HermesDiagnostics"]),
        .target(name: "HermesTransport", dependencies: ["HermesProtocol", "HermesDiagnostics"]),
        .target(
            name: "HermesClient",
            dependencies: ["HermesProtocol", "HermesDiagnostics", "HermesREST", "HermesAuth", "HermesTransport"]
        ),
        .target(
            name: "HermesChat",
            dependencies: [
                "HermesProtocol", "HermesDiagnostics", "HermesTransport", "HermesClient", "HermesREST", "HermesAuth",
            ]
        ),
        .target(name: "HermesRoster", dependencies: ["HermesProtocol", "HermesDiagnostics", "HermesTransport"]),
        .target(name: "HermesBotProfile", dependencies: ["HermesProtocol", "HermesDiagnostics", "HermesTransport", "HermesRoster"]),
        .target(name: "HermesRFB", dependencies: ["HermesDiagnostics"]),
        .target(name: "HermesDevice", dependencies: ["HermesProtocol", "HermesDiagnostics", "HermesTransport"]),
        .target(
            name: "HermesConnect",
            dependencies: ["HermesProtocol", "HermesDiagnostics", "HermesTransport", "HermesAuth"]
        ),
        .testTarget(
            name: "HermesKitTests",
            dependencies: [
                "HermesProtocol", "HermesDiagnostics", "HermesREST", "HermesAuth", "HermesTransport", "HermesClient",
                "HermesChat", "HermesRoster", "HermesBotProfile", "HermesRFB", "HermesDevice", "HermesConnect",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
