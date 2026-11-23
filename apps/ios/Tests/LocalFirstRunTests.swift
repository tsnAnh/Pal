#if os(macOS)
import Foundation
import PalAuth
import PalClient
import PalLocalEngine
import PalProtocol
import PalREST
import PalRoster
import Testing

@testable import Pal

private struct RefusingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cannotConnectToHost) }
}

@MainActor
private func makeConnection() throws -> ConnectionModel {
    let root = FileManager.default.temporaryDirectory.appending(path: "first-run-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .phone, appVersion: "0.1.0 (1)")
    return ConnectionModel(
        auth: try AuthSession(store: InMemoryCredentialStore(), transport: RefusingTransport()),
        transport: RefusingTransport(),
        diagnostics: .silent,
        initialBaseURL: "http://first-run-tests.invalid",
        presence: ReachPresence(identity: identity),
        cache: CacheStore(root: root)
    )
}

@MainActor
@Suite("Local first run", .serialized)
struct LocalFirstRunTests {
    @Test func finishingSetupWithoutASignInDoesNothing() throws {
        let connection = try makeConnection()
        connection.finishLocalSetup(greets: true)
        #expect(connection.localFirstRun == .inactive)
        #expect(!connection.ownerIntroPending)
        #expect(!connection.holdsLaunchConversation)
    }

    @Test func aFailedSignInReleasesTheChatHold() async throws {
        let connection = try makeConnection()
        let session = EngineSession(port: 9300, home: FileManager.default.temporaryDirectory)
        let signedIn = await connection.signInToLocalEngine(session)
        #expect(!signedIn)
        #expect(connection.localFirstRun == .inactive)
        #expect(!connection.holdsLaunchConversation)
    }
}
#endif
