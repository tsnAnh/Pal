import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport
import Synchronization

final class CustomRPC: ConnectRPC {
    typealias Reply = @Sendable (JSONValue) throws -> JSONValue

    private let replies: Mutex<[String: Reply]>
    private let log = Mutex<[(String, JSONValue)]>([])

    init(_ replies: [String: Reply]) { self.replies = Mutex(replies) }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        log.withLock { $0.append((method, params)) }
        guard let reply = replies.withLock({ $0[method] }) else {
            throw GatewayTransportError.rpc(RPCError(code: -32601, message: "unknown_method"))
        }
        return try reply(params)
    }

    func methods() -> [String] { log.withLock { $0.map(\.0) } }
    func params(_ method: String) -> [JSONValue] { log.withLock { $0.filter { $0.0 == method }.map(\.1) } }
    func everything() -> [(String, JSONValue)] { log.withLock { $0 } }
}

struct IdleBrowser: AuthorizationBrowser {
    func present(_ url: URL) async throws {}
    func dismiss() async {}
}

final class RecordingBrowser: AuthorizationBrowser {
    let presented = Mutex<[URL]>([])
    func present(_ url: URL) async throws { presented.withLock { $0.append(url) } }
    func dismiss() async {}
}

func rpcFailure(_ code: Int, reason: String? = nil, message: String = "failed") -> CustomRPC.Reply {
    { _ in
        throw GatewayTransportError.rpc(RPCError(code: code, message: message, data: reason.map { ["reason": .string($0)] }))
    }
}

func okTools(_ names: [String]) -> CustomRPC.Reply {
    { _ in ["ok": true, "tools": .array(names.map { ["name": .string($0), "description": .string("Does \($0)")] }), "oauth_needed": false, "oauth_tokens_present": false] }
}

func customService(_ rpc: CustomRPC, profile: String? = nil, system: any AuthorizationBrowser = IdleBrowser(), catalog: any AuthorizationBrowser = IdleBrowser()) -> ConnectAppsService {
    ConnectAppsService(
        rpc: rpc, profile: profile, browser: catalog, systemBrowser: system,
        timing: ConnectAppsTiming(pollInterval: .milliseconds(5), pollAttempts: 3)
    )
}

func randomSecret() -> String { "sec-" + UUID().uuidString + UUID().uuidString }

func oauthChallenge() -> JSONValue {
    ["ok": false, "reason": "auth_refused", "error": "401", "oauth_needed": true, "oauth_tokens_present": false]
}

final class CallCounter: Sendable {
    private let count = Mutex(0)
    func next() -> Int { count.withLock { value in value += 1; return value } }
}

func oauthThenTools(_ names: [String]) -> CustomRPC.Reply {
    let calls = CallCounter()
    return { params in
        let count = calls.next()
        return count == 1 ? oauthChallenge() : try okTools(names)(params)
    }
}

final class BlockingBrowser: AuthorizationBrowser {
    let presented = Mutex<[URL]>([])
    func present(_ url: URL) async throws {
        presented.withLock { $0.append(url) }
        try await Task.sleep(for: .seconds(60))
    }
    func dismiss() async {}
}
