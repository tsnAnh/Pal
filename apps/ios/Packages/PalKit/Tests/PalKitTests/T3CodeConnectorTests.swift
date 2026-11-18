import Foundation
@testable import PalConnect
import PalProtocol
import Testing

@Suite("T3 Code address")
struct T3CodeAddressTests {
    private func failure(_ input: String) -> T3AddressError? {
        do { _ = try T3CodeConnector.mcpURL(fromInput: input); return nil } catch { return error }
    }

    @Test(arguments: ["100.64.0.1", "100.109.203.70", "100.127.255.255", "host.tailnet-name.ts.net", "MAC.Tail1234.TS.NET"])
    func tailnetAddressesAreOnYourOwnNetwork(host: String) {
        #expect(PrivateHost.isPrivate(host))
    }

    @Test(arguments: ["100.63.255.255", "100.128.0.1", "8.8.8.8", "example.com", "evilts.net", "ts.net.evil.com", "ts.net", ".ts.net", "100.64.0"])
    func everythingElseStaysPublic(host: String) {
        #expect(!PrivateHost.isPrivate(host))
    }

    @Test func theCustomConnectorAcceptsPlainHttpOnTheTailnetOnly() throws {
        #expect(try ConnectorURL.validated("http://100.109.203.70:3773/mcp") == "http://100.109.203.70:3773/mcp")
        #expect(try ConnectorURL.validated("http://mac.tail1234.ts.net:3773/mcp") == "http://mac.tail1234.ts.net:3773/mcp")
        do {
            _ = try ConnectorURL.validated("http://example.com/mcp")
            Issue.record("a public host over plain http must be refused")
        } catch {
            #expect(error == .insecureURL)
        }
    }

    @Test(arguments: [
        ("100.109.203.70", "http://100.109.203.70:3773/mcp"),
        ("100.109.203.70:3773", "http://100.109.203.70:3773/mcp"),
        ("  100.109.203.70:4000  ", "http://100.109.203.70:4000/mcp"),
        ("http://100.109.203.70:3773", "http://100.109.203.70:3773/mcp"),
        ("HTTP://100.109.203.70:3773/", "http://100.109.203.70:3773/mcp"),
        ("http://100.109.203.70:3773/mcp", "http://100.109.203.70:3773/mcp"),
        ("100.109.203.70/mcp", "http://100.109.203.70:3773/mcp"),
        ("mac.tail1234.ts.net:3773", "http://mac.tail1234.ts.net:3773/mcp"),
        ("http://mac.tail1234.ts.net", "http://mac.tail1234.ts.net:3773/mcp"),
        ("192.168.1.20:3773", "http://192.168.1.20:3773/mcp"),
        ("[::1]:3773", "http://[::1]:3773/mcp"),
        ("https://mac.tail1234.ts.net/mcp", "https://mac.tail1234.ts.net/mcp"),
        ("https://example.com:8443", "https://example.com:8443/mcp"),
    ])
    func everyWayOfTypingTheAddressBecomesOneMcpURL(input: String, expected: String) throws {
        #expect(try T3CodeConnector.mcpURL(fromInput: input) == expected)
    }

    @Test(arguments: [
        ("", T3AddressError.empty), ("   ", .empty),
        ("http://", .invalid), (":3773", .invalid), ("100.64.0.5:3773:1", .invalid), ("[::1", .invalid), ("100.64.0.5 :3773", .invalid),
        ("ftp://100.64.0.5", .unsupportedScheme), ("file:///etc/passwd", .unsupportedScheme),
        ("100.64.0.5:0", .invalidPort), ("100.64.0.5:65536", .invalidPort), ("100.64.0.5:99999", .invalidPort),
        ("100.64.0.5:abc", .invalidPort), ("100.64.0.5:", .invalidPort), ("100.64.0.5:-1", .invalidPort),
        ("100.64.0.5:3773/other", .wrongPath), ("100.64.0.5:3773/mcp/extra", .wrongPath), ("100.64.0.5:3773/mcp?x=1", .wrongPath),
        ("100.64.0.5:3773#top", .wrongPath), ("http://100.64.0.5/MCP", .wrongPath),
        ("user:pw@100.64.0.5:3773", .credentials), ("http://user@100.64.0.5:3773/mcp", .credentials),
        ("http://example.com/mcp", .insecure), ("example.com:3773", .insecure), ("8.8.8.8", .insecure), ("100.128.0.1:3773", .insecure),
        ("evilts.net:3773", .insecure), ("ts.net", .insecure), ("http://mac:3773/mcp", .insecure),
    ])
    func aWrongAddressIsRefusedWithTheRightReason(input: String, expected: T3AddressError) {
        #expect(failure(input) == expected, "\(input)")
    }

    @Test func aPublicHostOverPlainHttpUsesTheCustomConnectorReason() {
        #expect(failure("http://example.com/mcp")?.message == CustomConnectorValidationError.insecureURL.message)
    }

    @Test func everyAddressErrorSaysWhatToDoInPlainWords() {
        let all: [T3AddressError] = [.empty, .invalid, .unsupportedScheme, .credentials, .invalidPort, .wrongPath, .insecure]
        for error in all {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains("URL") && !error.message.contains("MCP"))
        }
    }

    @Test func theConnectorIsNamedAfterTheCatalogEntry() {
        #expect(T3CodeConnector.slug == "t3code")
        #expect(T3CodeConnector.name == "T3 Code")
        #expect(T3CodeConnector.defaultPort == 3773)
    }
}

@Suite("T3 Code row")
struct T3CodeRowTests {
    private func t3(_ state: ConnectAppState) -> ConnectApp {
        let entry = PalCatalogEntry(slug: "t3code", name: "T3 Code", category: "Developer tools", method: .mcpOAuth)
        return ConnectApp(id: "connector:t3code", name: "T3 Code", summary: "", category: "Developer tools", source: .catalog(entry), state: state)
    }

    private func other(_ state: ConnectAppState) -> ConnectApp {
        let entry = PalCatalogEntry(slug: "linear", name: "Linear", category: "Developer tools", method: .mcpOAuth)
        return ConnectApp(id: "connector:linear", name: "Linear", summary: "", category: "Developer tools", source: .catalog(entry), state: state)
    }

    @Test func onlyTheT3CodeCatalogRowIsT3Code() {
        #expect(t3(.connected).isT3Code)
        #expect(!other(.connected).isT3Code)
        let preset = ConnectApp(id: "mcp:t3code", name: "T3 Code", summary: "", category: "", source: .mcp(name: "t3code", requires: []), state: .connected)
        let custom = ConnectApp(
            id: "custom:t3code", name: "t3code", summary: "", category: "",
            source: .custom(CustomConnectorInfo(name: "t3code", url: "https://a.example.com")), state: .connected
        )
        #expect(!preset.isT3Code && !custom.isT3Code)
    }

    @Test func aConnectedRowThatCannotBeReachedNeedsAttention() {
        let app = t3(.connected).applying(t3Reach: .unreachable)
        #expect(app.state == .needsAuthorization)
        #expect(app.authReason == "T3 Code is not reachable")
        #expect(ConnectRowState.resolve(ConnectRowInput(app: app)) == .needsAttention(reason: "T3 Code is not reachable"))
        let row = ConnectListRow(app: app, state: ConnectRowState.resolve(ConnectRowInput(app: app)))
        #expect(row.summary == "T3 Code is not reachable" && row.hasProblem)
    }

    @Test func aConnectedRowThatNeedsSignInShowsTheExpiredSignIn() {
        let app = t3(.connected).applying(t3Reach: .needsSignIn)
        #expect(app.state == .needsAuthorization)
        #expect(app.authReason == ConnectRowState.expiredSignIn)
        #expect(ConnectRowState.resolve(ConnectRowInput(app: app)) == .needsAttention(reason: "Sign-in expired"))
    }

    @Test func aReachableOrUnknownProbeChangesNothing() {
        let app = t3(.connected)
        #expect(app.applying(t3Reach: .reachable) == app)
        #expect(app.applying(t3Reach: nil) == app)
        #expect(ConnectRowState.resolve(ConnectRowInput(app: app.applying(t3Reach: .reachable))) == .connected)
    }

    @Test(arguments: [ConnectAppState.disconnected, .needsAuthorization, .needsSetup])
    func aRowThatIsNotConnectedIsNeverRewritten(state: ConnectAppState) {
        for reach in [T3Reach.reachable, .needsSignIn, .unreachable] {
            #expect(t3(state).applying(t3Reach: reach) == t3(state))
        }
    }

    @Test func everyOtherAppIgnoresTheProbe() {
        for reach in [T3Reach.reachable, .needsSignIn, .unreachable] {
            #expect(other(.connected).applying(t3Reach: reach) == other(.connected))
        }
    }
}

@Suite("T3 Code catalog entry")
struct T3CodeCatalogTests {
    private func decode(_ json: JSONValue) throws -> PalCatalogEntry {
        try json.decoded(as: PalCatalogEntry.self)
    }

    private let entry: JSONValue = [
        "slug": "t3code", "name": "T3 Code", "method": "mcp_oauth", "status": "not_connected",
        "notes": "Runs on your own computer. Turn on Network access in T3 Code first.",
    ]

    @Test func anEntryWithoutAnAddressDecodes() throws {
        let decoded = try decode(entry)
        #expect(decoded.slug == "t3code" && decoded.name == "T3 Code" && decoded.method == .mcpOAuth)
        #expect(decoded.mcpURL == nil)
        #expect(decoded.status == .notConnected)
        #expect(decoded.notes == "Runs on your own computer. Turn on Network access in T3 Code first.")
    }

    @Test func aPlainHttpAddressIsStillDropped() throws {
        var object = entry.objectValue ?? [:]
        object["mcp_url"] = "http://100.109.203.70:3773/mcp"
        #expect(try decode(.object(object)).mcpURL == nil)
    }

    @Test func theRowOffersConnect() throws {
        var object = entry.objectValue ?? [:]
        object["verified"] = true
        let catalog = ConnectCatalog.make(catalog: [try decode(.object(object))], mcp: [])
        let app = try #require(catalog.apps.first)
        #expect(app.isT3Code && app.state == .disconnected)
        let state = ConnectRowState.resolve(ConnectRowInput(app: app))
        #expect(state == .connect)
        let row = ConnectListRow(app: app, state: state)
        #expect(row.state == .connect && row.summary == "Sign in with your account" && !row.hasProblem)
    }
}
