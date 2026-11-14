import Foundation
@testable import PalConnect
import PalProtocol
import PalT3Code
import Synchronization
import Testing

@Suite("T3 runtime file")
struct T3RuntimeTests {
    private func parse(_ origin: String, version: Int = 1, pid: Int = 10) throws -> T3Runtime {
        try T3Runtime.parse(Data(#"{"version":\#(version),"pid":\#(pid),"origin":"\#(origin)","extra":true}"#.utf8))
    }

    @Test(arguments: ["http://127.0.0.1:47391", "http://localhost:3773", "http://[::1]:3773", "http://127.0.0.1:47391/"])
    func acceptsLoopbackOrigins(_ origin: String) throws {
        let runtime = try parse(origin)
        #expect(runtime.origin.scheme == "http")
        #expect(runtime.mcpURL.path == "/mcp")
        #expect(runtime.pid == 10)
    }

    @Test(arguments: [
        "http://192.168.1.20:3773", "http://0.0.0.0:3773", "http://example.com:3773", "http://localhost.evil.com:3773",
        "https://127.0.0.1:3773", "http://127.0.0.1.evil.com:80",
    ])
    func rejectsAnythingThatIsNotPlainLoopbackHTTP(_ origin: String) {
        #expect(throws: T3RuntimeError.self) { try parse(origin) }
    }

    @Test(arguments: [
        "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:70000", "http://user:pw@127.0.0.1:3773",
        "http://127.0.0.1:3773/mcp", "http://127.0.0.1:3773?x=1", "http://127.0.0.1:3773#f", "", "not a url", "127.0.0.1:3773",
    ])
    func rejectsMalformedOrigins(_ origin: String) {
        #expect(throws: T3RuntimeError.self) { try parse(origin) }
    }

    @Test func rejectsUnknownVersionsAndBadPids() {
        #expect(throws: T3RuntimeError.unsupportedVersion) { try parse("http://127.0.0.1:3773", version: 2) }
        #expect(throws: T3RuntimeError.malformed) { try parse("http://127.0.0.1:3773", pid: 0) }
    }

    @Test func rejectsDocumentsThatAreNotTheExpectedShape() {
        for text in ["", "{}", "[]", #"{"version":1,"pid":4}"#, #"{"version":1,"origin":"http://127.0.0.1:1"}"#, #"{"version":"1","pid":4,"origin":"http://127.0.0.1:1"}"#] {
            #expect(throws: T3RuntimeError.self) { try T3Runtime.parse(Data(text.utf8)) }
        }
    }

    @Test func locatorIgnoresAStaleFileWhoseProcessIsGone() throws {
        let sandbox = try T3Sandbox()
        defer { sandbox.remove() }
        try sandbox.publish(origin: "http://127.0.0.1:3773", pid: 99)
        let alive = T3Locator(runtimeFile: sandbox.runtimeFile, applicationDirectories: [], processAlive: { _ in true })
        let gone = T3Locator(runtimeFile: sandbox.runtimeFile, applicationDirectories: [], processAlive: { _ in false })
        #expect(alive.runtime()?.pid == 99)
        #expect(gone.runtime() == nil)
    }

    @Test func locatorFindsTheInstalledApplicationByName() throws {
        let sandbox = try T3Sandbox()
        defer { sandbox.remove() }
        let locator = sandbox.locator
        #expect(locator.installedApplication() == nil)
        try FileManager.default.createDirectory(at: sandbox.directory.appending(path: "T3 Code (Beta).app"), withIntermediateDirectories: true)
        #expect(locator.installedApplication()?.lastPathComponent == "T3 Code (Beta).app")
    }

    @Test func systemProcessCheckSeesThisProcessAndNotAnImpossiblePid() {
        #expect(T3Locator.systemProcessAlive(ProcessInfo.processInfo.processIdentifier))
        #expect(!T3Locator.systemProcessAlive(Int32.max))
    }
}

@Suite("T3 connection state")
struct T3CodeStatusTests {
    private func run(_ events: [T3CodeEvent], from start: T3CodeStatus = T3CodeStatus()) -> T3CodeConnection {
        events.reduce(start) { $0.applying($1) }.connection
    }

    @Test func startsNotInstalled() {
        #expect(T3CodeStatus().connection == .notInstalled)
    }

    @Test func installedButNotRunningAsksToOpenIt() {
        #expect(run([.installationChecked(true)]) == .notRunning)
        #expect(run([.installationChecked(true), .runtimeSeen, .runtimeGone]) == .notRunning)
    }

    @Test func aRunningServerCountsAsInstalled() {
        #expect(run([.runtimeSeen, .tokenMissing]) == .signedOut)
    }

    @Test func signingInMovesThroughConnectingToConnected() {
        var status = T3CodeStatus()
        status.apply(.installationChecked(true))
        status.apply(.runtimeSeen)
        status.apply(.tokenMissing)
        #expect(status.connection == .signedOut)
        status.apply(.signInStarted)
        #expect(status.connection == .connecting)
        status.apply(.signInSucceeded)
        #expect(status.connection == .connected)
    }

    @Test func aSavedTokenWithServerRunningIsConnectedOnLaunch() {
        #expect(run([.installationChecked(true), .runtimeSeen, .tokenFound(expired: false)]) == .connected)
    }

    @Test func aSavedTokenWithServerStoppedWaitsForTheServer() {
        #expect(run([.installationChecked(true), .tokenFound(expired: false)]) == .notRunning)
    }

    @Test func anExpiredTokenNeedsSignIn() {
        #expect(run([.runtimeSeen, .tokenFound(expired: true)]) == .needsSignIn(.expired))
    }

    @Test func aSeen401NeedsSignInAndSignInRecovers() {
        var status = T3CodeStatus(installed: true, running: true, credential: .saved)
        status.apply(.unauthorized)
        #expect(status.connection == .needsSignIn(.rejected))
        status.apply(.signInStarted)
        status.apply(.signInSucceeded)
        #expect(status.connection == .connected)
    }

    @Test func aFailedSignInShowsItsReasonAndKeepsTheOldCredentialUnusable() {
        var status = T3CodeStatus(installed: true, running: true, credential: .unusable(.rejected))
        status.apply(.signInStarted)
        status.apply(.signInFailed(.signIn(.denied)))
        #expect(status.connection == .failed(.signIn(.denied)))
        #expect(status.credential == .unusable(.rejected))
    }

    @Test func cancellingSignInReturnsToSignedOut() {
        #expect(run([.runtimeSeen, .tokenMissing, .signInStarted, .signInCancelled]) == .signedOut)
    }

    @Test func registrationFailureClearsOnlyWhenRegistrationSucceeds() {
        var status = T3CodeStatus(installed: true, running: true, credential: .saved)
        status.apply(.registrationFailed)
        #expect(status.connection == .failed(.registration))
        status.apply(.registrationSucceeded)
        #expect(status.connection == .connected)
        status.apply(.signInFailed(.storage))
        status.apply(.registrationSucceeded)
        #expect(status.connection == .failed(.storage))
    }

    @Test func disconnectDropsTheCredentialWhateverTheState() {
        var status = T3CodeStatus(installed: true, running: true, credential: .unusable(.expired), attempt: .failed(.registration))
        status.apply(.disconnectTapped)
        #expect(status.connection == .signedOut)
    }

    @Test func theServerGoingAwayEndsAPendingSignIn() {
        #expect(run([.installationChecked(true), .runtimeSeen, .tokenMissing, .signInStarted, .runtimeGone]) == .notRunning)
    }

    @Test func rowTextMatchesTheProductCopy() {
        #expect(T3CodeRowPresentation(.notInstalled).summary == "Install T3 Code on this Mac")
        #expect(T3CodeRowPresentation(.notInstalled).buttonTitle == nil)
        let notRunning = T3CodeRowPresentation(.notRunning)
        #expect(notRunning.summary == "Open T3 Code to connect")
        #expect(notRunning.buttonTitle == "Open T3 Code")
        #expect(notRunning.action == .openApp)
        #expect(T3CodeRowPresentation(.signedOut).buttonTitle == "Connect")
        #expect(T3CodeRowPresentation(.connecting).isBusy)
        #expect(T3CodeRowPresentation(.connected).action == .disconnect)
        #expect(T3CodeRowPresentation(.needsSignIn(.rejected)).buttonTitle == "Sign in again")
        #expect(T3CodeRowPresentation(.failed(.registration)).buttonTitle == "Try again")
        #expect(T3CodeRowPresentation.title == "T3 Code")
    }
}

private final class SeenURLs: Sendable {
    private let urls = Mutex<[URL]>([])

    func withLock<R: Sendable>(_ body: (inout [URL]) -> R) -> R { urls.withLock { body(&$0) } }
}

private struct FakeAuthorizer: T3Authorizing {
    enum Outcome: Sendable {
        case token(String)
        case fail(McpOAuthError)
        case hang
    }

    let outcome: Outcome
    let seen: SeenURLs

    func authorize(resource: URL) async throws -> McpOAuthGrant {
        seen.withLock { $0.append(resource) }
        switch outcome {
        case .token(let token):
            return McpOAuthGrant(
                clientID: "c", redirectURI: "http://127.0.0.1:1/callback", tokenEndpoint: resource, issuer: "i",
                accessToken: SecretString(token), refreshToken: nil, expiresIn: 3600, scope: nil, tokenType: "Bearer"
            )
        case .fail(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw McpOAuthError.timedOut
        }
    }
}

private final class FakeRegistrar: T3Registering {
    let registerCalls = Mutex(0)
    let unregisterCalls = Mutex(0)
    let failing = Mutex(false)

    func register() async throws {
        registerCalls.withLock { $0 += 1 }
        if failing.withLock({ $0 }) { throw McpOAuthError.gatewayUnavailable }
    }

    func unregister() async {
        unregisterCalls.withLock { $0 += 1 }
    }
}

@MainActor
private struct ControllerRig {
    let sandbox: T3Sandbox
    let tokens: InMemoryT3TokenStore
    let registrar = FakeRegistrar()
    let seen = SeenURLs()
    let controller: T3CodeController

    init(outcome: FakeAuthorizer.Outcome = .token("fresh-token"), token: T3Token? = nil, running: Bool = true, installed: Bool = true) throws {
        sandbox = try T3Sandbox()
        tokens = InMemoryT3TokenStore(token)
        if running { try sandbox.publish(origin: "http://127.0.0.1:47391") }
        if installed { try FileManager.default.createDirectory(at: sandbox.directory.appending(path: "T3 Code (Beta).app"), withIntermediateDirectories: true) }
        controller = T3CodeController(
            locator: sandbox.locator, tokens: tokens, authorizer: FakeAuthorizer(outcome: outcome, seen: seen), registrar: registrar
        )
    }
}

@MainActor
@Suite("T3 connect controller")
struct T3CodeControllerTests {
    private let saved = T3Token(access: SecretString("saved-token"), expiresAt: nil)

    @Test func launchWithSavedTokenAndRunningServerRegistersOnceAndIsConnected() async throws {
        let rig = try ControllerRig(token: saved)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        await rig.controller.refresh()
        #expect(rig.controller.connection == .connected)
        #expect(rig.registrar.registerCalls.withLock { $0 } == 1)
    }

    @Test func aServerThatRestartsIsRegisteredAgain() async throws {
        let rig = try ControllerRig(token: saved)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        try rig.sandbox.publish(origin: "http://127.0.0.1:47392", pid: 5151)
        await rig.controller.refresh()
        #expect(rig.registrar.registerCalls.withLock { $0 } == 2)
    }

    @Test func notRunningNeverRegisters() async throws {
        let rig = try ControllerRig(token: saved, running: false)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        #expect(rig.controller.connection == .notRunning)
        #expect(rig.registrar.registerCalls.withLock { $0 } == 0)
    }

    @Test func notInstalledAndNotRunningIsReported() async throws {
        let rig = try ControllerRig(running: false, installed: false)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        #expect(rig.controller.connection == .notInstalled)
    }

    @Test func connectSignsInAgainstTheServersMcpEndpointStoresTheTokenAndRegisters() async throws {
        let rig = try ControllerRig()
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        #expect(rig.controller.connection == .signedOut)
        await rig.controller.connect()
        #expect(rig.controller.connection == .connected)
        #expect(rig.seen.withLock { $0 }.map(\.absoluteString) == ["http://127.0.0.1:47391/mcp"])
        #expect(try rig.tokens.load()?.access.reveal() == "fresh-token")
        #expect(try rig.tokens.load()?.expiresAt != nil)
        #expect(rig.registrar.registerCalls.withLock { $0 } == 1)
    }

    @Test func aFailedSignInShowsTheReasonAndStoresNothing() async throws {
        let rig = try ControllerRig(outcome: .fail(.denied))
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        await rig.controller.connect()
        #expect(rig.controller.connection == .failed(.signIn(.denied)))
        #expect(try rig.tokens.load() == nil)
        #expect(rig.registrar.registerCalls.withLock { $0 } == 0)
    }

    @Test func aCancelledSignInGoesQuietlyBackToSignedOut() async throws {
        let rig = try ControllerRig(outcome: .hang)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        let connecting = Task { await rig.controller.connect() }
        for _ in 0..<200 where rig.controller.connection != .connecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.controller.connection == .connecting)
        rig.controller.cancelSignIn()
        await connecting.value
        #expect(rig.controller.connection == .signedOut)
    }

    @Test func connectWhileTheServerIsDownDoesNothing() async throws {
        let rig = try ControllerRig(running: false)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        await rig.controller.connect()
        #expect(rig.seen.withLock { $0 }.isEmpty)
        #expect(rig.controller.connection == .notRunning)
    }

    @Test func aRegistrationFailureRetriesOnTheNextRefreshWithoutSigningInAgain() async throws {
        let rig = try ControllerRig()
        defer { rig.sandbox.remove() }
        rig.registrar.failing.withLock { $0 = true }
        await rig.controller.refresh()
        await rig.controller.connect()
        #expect(rig.controller.connection == .failed(.registration))
        rig.registrar.failing.withLock { $0 = false }
        await rig.controller.refresh()
        #expect(rig.controller.connection == .connected)
        #expect(rig.seen.withLock { $0 }.count == 1)
    }

    @Test func aRejectedTokenStaysRejectedAcrossRefreshesUntilANewSignIn() async throws {
        let rig = try ControllerRig(token: saved)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        rig.controller.unauthorized()
        await rig.controller.refresh()
        #expect(rig.controller.connection == .needsSignIn(.rejected))
        await rig.controller.connect()
        #expect(rig.controller.connection == .connected)
        #expect(try rig.tokens.load()?.access.reveal() == "fresh-token")
    }

    @Test func anExpiredTokenNeedsSignInAndNeverRegisters() async throws {
        let expired = T3Token(access: SecretString("old"), expiresAt: Date().addingTimeInterval(-5))
        let rig = try ControllerRig(token: expired)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        #expect(rig.controller.connection == .needsSignIn(.expired))
        #expect(rig.registrar.registerCalls.withLock { $0 } == 0)
    }

    @Test func disconnectUnregistersDeletesTheTokenAndForgetsTheRegistration() async throws {
        let rig = try ControllerRig(token: saved)
        defer { rig.sandbox.remove() }
        await rig.controller.refresh()
        await rig.controller.disconnect()
        #expect(rig.controller.connection == .signedOut)
        #expect(try rig.tokens.load() == nil)
        #expect(rig.registrar.unregisterCalls.withLock { $0 } == 1)
        await rig.controller.refresh()
        #expect(rig.controller.connection == .signedOut)
        #expect(rig.registrar.registerCalls.withLock { $0 } == 1)
    }
}
