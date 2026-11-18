import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Synchronization
import Testing

private struct LoopbackBrowser: AuthorizationBrowser {
    func present(_ url: URL) async throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let target = items.first(where: { $0.name == "redirect_uri" })?.value, var back = URLComponents(string: target) else { return }
        back.queryItems = [URLQueryItem(name: "code", value: "abc"), URLQueryItem(name: "state", value: "st-1")]
        _ = try await URLSession.shared.data(from: back.url!)
        try await Task.sleep(for: .seconds(10))
    }

    func dismiss() async {}
}

private struct Slot: Sendable {
    var added: Bool
    var live: Int?
    var starts = 0
}

private func refusal(_ code: Int, _ message: String) -> GatewayTransportError {
    GatewayTransportError.rpc(RPCError(code: code, message: message))
}

private func slotGateway(alreadyAdded: Bool, approveFrom firstApproved: Int) -> CustomRPC {
    let slot = Mutex(Slot(added: alreadyAdded))
    return CustomRPC([
        "mcp.servers.add": { _ in
            let duplicate = slot.withLock { (s: inout Slot) -> Bool in
                let was = s.added
                s.added = true
                return was
            }
            if duplicate { throw refusal(4090, "server 'notion' already exists") }
            return ["ok": true]
        },
        "mcp.servers.remove": { _ in
            slot.withLock { (s: inout Slot) in s.added = false }
            return ["ok": true]
        },
        "mcp.servers.oauth.start": { params in
            let started = slot.withLock { (s: inout Slot) -> Int? in
                if s.live != nil { return nil }
                s.starts += 1
                s.live = s.starts
                return s.starts
            }
            guard let id = started else { throw refusal(5024, "MCP OAuth for 'notion' is already in progress") }
            let redirect = params["client_redirect_uri"]?.stringValue ?? ""
            let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let link = "https://auth.example.com/authorize?response_type=code&state=st-1&redirect_uri=\(encoded)"
            return ["session_id": .string("s\(id)"), "auth_url": .string(link)]
        },
        "mcp.servers.oauth.callback": { _ in ["ok": true] },
        "mcp.servers.oauth.poll": { params in
            let id = Int(params["session_id"]?.stringValue?.dropFirst() ?? "") ?? 0
            guard id >= firstApproved else { return ["status": "pending"] }
            slot.withLock { (s: inout Slot) in s.live = nil }
            return ["status": "approved"]
        },
        "mcp.servers.oauth.cancel": { _ in
            slot.withLock { (s: inout Slot) in s.live = nil }
            return ["ok": true]
        },
    ])
}

private let notion = catalogEntry("notion", "Notion", "Files and docs", method: .mcpOAuth, url: "https://mcp.notion.com/mcp")
private let notionApp = ConnectApp(
    id: "connector:notion", name: "Notion", summary: "", category: "Files and docs", source: .catalog(notion), state: .disconnected
)

private func service(_ rpc: CustomRPC) -> ConnectAppsService {
    ConnectAppsService(
        rpc: rpc, profile: nil, browser: LoopbackBrowser(),
        timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
    )
}

@Suite("Connecting twice in a row")
struct ConnectRetryTests {
    @Test func aServerThatAlreadyExistsConnectsOnEveryClickAndIsNeverRemoved() async throws {
        let rpc = slotGateway(alreadyAdded: true, approveFrom: 1)
        try await service(rpc).connect(notionApp)
        try await service(rpc).connect(notionApp)
        #expect(rpc.methods().filter { $0 == "mcp.servers.oauth.start" }.count == 2)
        #expect(!rpc.methods().contains("mcp.servers.remove"))
    }

    @Test func aSignInThatTimedOutFreesTheGatewaySlotSoTheNextClickConnects() async throws {
        let rpc = slotGateway(alreadyAdded: false, approveFrom: 2)
        await #expect(throws: ConnectAppsError.signInFailed(McpSignInFailure.expired.reason)) { try await service(rpc).connect(notionApp) }
        #expect(rpc.params("mcp.servers.oauth.cancel").first?["session_id"]?.stringValue == "s1")
        try await service(rpc).connect(notionApp)
        #expect(rpc.methods().filter { $0 == "mcp.servers.oauth.start" }.count == 2)
    }

    @Test func aRefusedAddKeepsTheGatewayFaultForTheStatusView() async {
        let rpc = CustomRPC(["mcp.servers.add": rpcFailure(4063, reason: "invalid_url")])
        do {
            try await service(rpc).connect(notionApp)
            Issue.record("connect should have failed")
        } catch let error as ConnectAppsError {
            #expect(error.fault?.code == 4063)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
