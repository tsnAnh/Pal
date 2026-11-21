import Foundation
import PalDevice
import PalProtocol
import Testing

private func required(service: String, name: String = "Upwork", requestID: String = "r1", signinOn: String? = "owner_app") -> GatewayEvent {
    var payload: [String: JSONValue] = [
        "request_id": .string(requestID), "service": .string(service), "service_name": .string(name), "bot": "atlas",
        "reason": "revoked", "flow": "oauth",
    ]
    if let signinOn { payload["signin_on"] = .string(signinOn) }
    return GatewayEvent(type: "auth.required", payload: .object(payload))
}

@Suite("MCP service identifiers")
struct McpServiceIDTests {
    @Test func aPlainServiceHasNoAccount() {
        let id = McpServiceID(service: "mcp:upwork")
        #expect(id?.slug == "upwork")
        #expect(id?.account == nil)
        #expect(id?.service == "mcp:upwork")
    }

    @Test func anAccountServiceCarriesItsAlias() {
        let id = McpServiceID(service: "mcp:upwork:work")
        #expect(id?.slug == "upwork")
        #expect(id?.account == "work")
        #expect(id?.service == "mcp:upwork:work")
        #expect(McpServiceID(service: "mcp:google-ads:a-b")?.account == "a-b")
    }

    @Test(arguments: [
        "", "mcp", "mcp:", "mcp::work", "mcp:upwork:", "mcp:upwork:Work", "mcp:upwork:-a", "mcp:upwork:a b", "mcp:a:b:c",
        "google:workspace", "github", "MCP:upwork",
    ])
    func anythingElseIsNotAnMcpService(_ service: String) {
        #expect(McpServiceID(service: service) == nil)
    }

    @Test func buildingOneRoundTrips() {
        #expect(McpServiceID(slug: "upwork", account: nil).service == "mcp:upwork")
        #expect(McpServiceID(slug: "upwork", account: "work").service == "mcp:upwork:work")
        #expect(McpServiceID(service: McpServiceID(slug: "t3code", account: "me").service) == McpServiceID(slug: "t3code", account: "me"))
    }

    @Test func theTitleNamesTheAccountInProductLanguage() {
        #expect(McpServiceID(service: "mcp:upwork:work")?.displayTitle(vendor: "Upwork") == "Upwork (work)")
        #expect(McpServiceID(service: "mcp:upwork")?.displayTitle(vendor: "Upwork") == "Upwork")
        #expect(McpServiceID(service: "mcp:upwork:work")?.displayTitle(vendor: "Upwork (work)") == "Upwork (work)")
        let title = McpServiceID(service: "mcp:upwork:work")?.displayTitle(vendor: "Upwork") ?? ""
        #expect(!title.contains("mcp"))
        #expect(!title.contains(":"))
        #expect(!title.contains("@"))
    }
}

@Suite("Sign-in required for one account")
struct AuthRequiredAccountTests {
    @Test func theAccountServiceIsAcceptedAndTheAliasKept() throws {
        let event = try #require(AuthRequiredEvent(event: required(service: "mcp:upwork:work")))
        #expect(event.service == "mcp:upwork:work")
        #expect(event.mcpService == McpServiceID(slug: "upwork", account: "work"))
        #expect(event.account == "work")
        #expect(event.displayTitle == "Upwork (work)")
        #expect(event.requiresAppSignIn)
    }

    @Test func thePlainServiceStillWorks() throws {
        let event = try #require(AuthRequiredEvent(event: required(service: "mcp:upwork")))
        #expect(event.account == nil)
        #expect(event.mcpService?.slug == "upwork")
        #expect(event.displayTitle == "Upwork")
    }

    @Test func aServiceThatIsNotMcpHasNoAccount() throws {
        let event = try #require(AuthRequiredEvent(event: required(service: "google:workspace", name: "Google Workspace")))
        #expect(event.mcpService == nil)
        #expect(event.account == nil)
        #expect(event.displayTitle == "Google Workspace")
    }

    @Test func aTitleTheGatewayAlreadyNamedIsNotNamedTwice() throws {
        let event = try #require(AuthRequiredEvent(event: required(service: "mcp:upwork:work", name: "Upwork (work)")))
        #expect(event.displayTitle == "Upwork (work)")
    }
}

@MainActor
@Suite("Sign-in dialogs per account")
struct ServiceSignInAccountTests {
    private func center(_ seen: SeenServices = SeenServices()) -> ServiceSignInCenter {
        ServiceSignInCenter(
            call: { _, _ in [:] }, openBrowser: { _ in },
            nativeSignIn: { service in seen.add(service); return .signedIn },
            dismissDelay: .seconds(60)
        )
    }

    @Test func theDialogKeepsTheAliasAndTheTitle() {
        let center = center()
        center.receive(required(service: "mcp:upwork:work"))
        #expect(center.current?.account == "work")
        #expect(center.current?.displayTitle == "Upwork (work)")
    }

    @Test func eachAccountGetsItsOwnDialog() {
        let center = center()
        center.receive(required(service: "mcp:upwork:work", requestID: "a"))
        center.receive(required(service: "mcp:upwork:default", requestID: "b"))
        #expect(center.dialogs.map(\.account) == ["work", "default"])
        #expect(center.pendingReason(for: "mcp:upwork:work") == .revoked)
        #expect(center.pendingReason(for: "mcp:upwork") == nil)
    }

    @Test func theNativeRouteReceivesTheAccountServiceSoTheRightAccountIsSignedBackIn() async {
        let seen = SeenServices()
        let center = center(seen)
        center.receive(required(service: "mcp:upwork:work"))
        await center.signIn()
        #expect(seen.all == ["mcp:upwork:work"])
        #expect(center.current?.phase == .signedIn)
    }
}

final class SeenServices: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [String] = []
    var all: [String] { lock.withLock { services } }
    func add(_ service: String) { lock.withLock { services.append(service) } }
}
