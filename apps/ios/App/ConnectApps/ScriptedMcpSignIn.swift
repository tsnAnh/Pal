import Foundation
import PalAuth
import PalConnect
import PalProtocol
import PalTransport

enum McpSignInScript {
    static let argument = "-hermes-test-mcp-signin"
    static let server = "notion"
    static let state = "scripted-state"
    static let code = "scripted-code"
    static let session = "scripted-session"
    static let authorize = "https://auth.example.test/authorize"

    enum Mode: String, Sendable {
        case refuseRedirect = "refuse-redirect"
        case staleThenConnect = "stale-then-connect"
        case admin
        case adminWords = "admin-words"
        case connect
        case wait
    }

    static var mode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let next = index + 1
        return Mode(rawValue: next < arguments.count ? arguments[next] : "") ?? .connect
    }

    static func wrap(_ rpc: any ConnectRPC) -> any ConnectRPC {
        guard let mode else { return rpc }
        return ScriptedMcpSignInRPC(base: rpc, mode: mode)
    }

    static func browser(_ real: any AuthorizationBrowser) -> any AuthorizationBrowser {
        mode == nil ? real : SystemBrowserAuthorization()
    }
}

actor ScriptedMcpSignInRPC: ConnectRPC {
    private let base: any ConnectRPC
    private let mode: McpSignInScript.Mode
    private var starts = 0

    init(base: any ConnectRPC, mode: McpSignInScript.Mode) {
        self.base = base
        self.mode = mode
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard params["name"]?.stringValue == McpSignInScript.server else { return try await base.call(method, params) }
        switch method {
        case "mcp.servers.add", "mcp.servers.remove", "mcp.servers.oauth.cancel", "mcp.servers.oauth.callback":
            return ["ok": true]
        case "mcp.servers.oauth.poll":
            return ["status": "approved"]
        case "mcp.servers.oauth.start":
            return try start(params)
        default:
            return try await base.call(method, params)
        }
    }

    private func start(_ params: JSONValue) throws -> JSONValue {
        starts += 1
        switch mode {
        case .refuseRedirect:
            throw Self.refusal(message: "redirect_uri is not allowed", reason: "invalid_redirect_uri")
        case .staleThenConnect where starts == 1:
            throw Self.refusal(message: "a sign-in is already open", reason: "oauth_in_progress")
        case .admin:
            throw GatewayTransportError.rpc(RPCError(
                code: 4033, message: "An admin of your organisation needs to approve Pal.",
                data: ["trace": "scriptedtr", "reason": "ADMIN_APPROVAL_PENDING"]
            ))
        case .adminWords:
            throw Self.refusal(message: "Admin approval is required for this application", reason: "access_denied")
        default:
            break
        }
        let redirect = params["client_redirect_uri"]?.stringValue ?? ""
        let encoded = redirect.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let link = "\(McpSignInScript.authorize)?response_type=code&state=\(McpSignInScript.state)&redirect_uri=\(encoded)"
        if mode != .wait { Self.playLoopbackBrowser(redirect) }
        return ["session_id": .string(McpSignInScript.session), "auth_url": .string(link)]
    }

    private static func playLoopbackBrowser(_ redirect: String) {
        #if os(macOS)
        guard redirect.hasPrefix("http://127.0.0.1:"), var parts = URLComponents(string: redirect) else { return }
        parts.queryItems = [
            URLQueryItem(name: "code", value: McpSignInScript.code), URLQueryItem(name: "state", value: McpSignInScript.state),
        ]
        guard let url = parts.url else { return }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(1500))
            _ = try? await URLSession.shared.data(from: url)
        }
        #endif
    }

    private static func refusal(message: String, reason: String) -> GatewayTransportError {
        .rpc(RPCError(code: 5000, message: message, data: ["trace": "scriptedtr", "reason": .string(reason)]))
    }
}
