import Foundation
import PalAuth
import PalClient
import PalConnect
import PalDiagnostics
import PalProtocol
import PalREST
import PalRoster
import Testing

@testable import HermesBots

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cannotConnectToHost) }
}

private let tester = "connect-apps-mac-tests"

@MainActor
private func makeModel(_ apps: [ConnectApp]) throws -> ConnectAppsModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "connect-apps-mac-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .phone, appVersion: "0.1.0 (1)")
    let transport = OfflineTransport()
    let connection = ConnectionModel(
        auth: try AuthSession(store: InMemoryCredentialStore(), transport: transport),
        transport: transport,
        diagnostics: .silent,
        initialBaseURL: "http://connect-apps-mac-tests.invalid",
        presence: ReachPresence(identity: identity),
        cache: CacheStore(root: root)
    )
    connection.surfaces.remember(ConnectCatalog(apps: apps), SurfaceKey.screen("connect-catalog", bot: tester))
    return ConnectAppsModel(
        connection: connection, pool: DeviceHostPool(botName: { $0 }), profile: tester, botName: "Tester", browser: UnavailableAuthorizationBrowser()
    )
}

private func app(_ id: String, _ category: String, _ state: ConnectAppState = .disconnected) -> ConnectApp {
    ConnectApp(id: id, name: id.capitalized, summary: "", category: category, source: .mcp(name: id, requires: []), state: state)
}

private let sample = [
    app("github", "Developer tools"), app("sentry", "Developer tools"), app("stripe", "Finance"),
    app("slack", "Communication", .connected), app("linear", "Work management", .needsAuthorization),
]

@Suite("Connect Apps on the Mac", .serialized)
@MainActor
struct ConnectAppsMacTests {
    @Test func sectionsAreBuiltOncePerDataChangeAndRowsAreFilteredFromTheCache() throws {
        let model = try makeModel(sample)
        for _ in 0..<6 { _ = model.macState }
        #expect(model.sectionBuilds == 1)
        #expect(model.rowBuilds == 1)

        model.query = "git"
        for _ in 0..<3 { _ = model.macState }
        #expect(model.sectionBuilds == 2)
        #expect(model.rowBuilds == 1)

        model.selectChip(.category("Finance"))
        for _ in 0..<3 { _ = model.macState }
        #expect(model.sectionBuilds == 3)
        #expect(model.rowBuilds == 1)

        model.busy.insert("github")
        _ = model.macState
        _ = model.macState
        #expect(model.rowBuilds == 2)
        #expect(model.sectionBuilds == 4)
    }

    @Test func theSharedRowCacheAlsoServesTheIPhoneListWithoutARebuild() throws {
        let model = try makeModel(sample)
        for _ in 0..<4 { _ = model.listSections }
        _ = model.macState
        #expect(model.rowBuilds == 1)
    }

    @Test func connectedAppsLiveBehindTheCountAndNeverInTheGrid() throws {
        let model = try makeModel(sample)
        let state = model.macState
        let gridIDs = Set(state.sections.flatMap { $0.entries.map(\.app.id) })
        #expect(!gridIDs.contains("slack"))
        #expect(state.installed.contains { $0.id == "slack" })
        #expect(state.sections.first?.section.kind == .needsAttention)
        #expect(!state.sections.map(\.section.title).contains("Recommended for you"))
        #expect(!state.sections.map(\.section.title).contains("Bot templates"))
        #expect(state.installed.allSatisfy { $0.countLine == "1 connector" })
    }

    @Test func escapeIsBackOnTheConnectedScreenAndClosesTheDialogOnTheMainScreen() throws {
        let model = try makeModel(sample)
        #expect(model.navigation.cancelAction == .closePanel)
        #expect(model.navigation.liveCancelActions == 1)
        model.showInstalled()
        #expect(model.navigation.cancelAction == .back)
        #expect(!model.navigation.showsPanelClose)
        #expect(model.navigation.liveCancelActions == 1)
        model.leaveInstalled()
        #expect(model.navigation.cancelAction == .closePanel)
        #expect(model.navigation.liveCancelActions == 1)
    }

    @Test func aLogoIsLookedUpOnceNoMatterHowOftenARowIsDrawn() {
        var lookups = 0
        let cache = ConnectorLogoCache { name in
            lookups += 1
            return name.hasSuffix("/github")
        }
        for _ in 0..<5 {
            #expect(cache.hasImage(named: "ConnectorLogos/github"))
            #expect(!cache.hasImage(named: "ConnectorLogos/missing"))
        }
        #expect(lookups == 2)
        #expect(cache.lookups == 2)
    }
}
