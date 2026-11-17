import Foundation
import PalConnect
import PalDevice
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization
import Testing

let googleAuthLink = "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&state=xyz"

func googleReply(_ value: JSONValue) -> CustomRPC.Reply { { _ in value } }

func gatewayError(_ code: Int, _ dataCode: String? = nil, message: String = "failed") -> CustomRPC.Reply {
    { _ in
        throw GatewayTransportError.rpc(RPCError(code: code, message: message, data: dataCode.map { .object(["code": .string($0)]) }))
    }
}

func googleStatusJSON(
    _ state: String, email: String? = nil, services: [String] = [], write: [String] = [], reason: String? = nil,
    extra: [String: JSONValue] = [:]
) -> JSONValue {
    var object: [String: JSONValue] = [
        "state": .string(state),
        "services": .array(services.map { .string($0) }),
        "write_services": .array(write.map { .string($0) }),
    ]
    if let email { object["email"] = .string(email) }
    if let reason { object["reauth_reason"] = .string(reason) }
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

func startReply(flow: String = "flow-1", url: String = googleAuthLink) -> JSONValue {
    .object(["flow_id": .string(flow), "auth_url": .string(url), "expires_in": .int(600)])
}

func finishReply(_ state: String, code: String? = nil, message: String? = nil, status: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue] = ["state": .string(state)]
    if let code { object["code"] = .string(code) }
    if let message { object["message"] = .string(message) }
    if let status { object["status"] = status }
    return .object(object)
}

func googleService(_ rpc: any ConnectRPC, diagnostics: Diagnostics = .silent) -> GoogleWorkspaceService {
    GoogleWorkspaceService(rpc: rpc, diagnostics: diagnostics)
}

final class ReplyQueue: Sendable {
    private let items: Mutex<[JSONValue]>

    init(_ items: [JSONValue]) { self.items = Mutex(items) }

    func next() -> JSONValue { items.withLock { $0.isEmpty ? finishReply("failed") : $0.removeFirst() } }
}

func googleStarted(_ rpc: any ConnectRPC, diagnostics: Diagnostics = .silent) async throws -> GoogleSignInSession {
    try await googleService(rpc, diagnostics: diagnostics).beginSignIn(GoogleScopeSelection())
}

func googleRendered(_ values: Any...) -> String {
    values.map { value in
        var dumped = ""
        dump(value, to: &dumped)
        return "\(String(describing: value))\n\(String(reflecting: value))\n\(dumped)"
    }
    .joined(separator: "\n")
}

let googleSignedInStatus = googleStatusJSON("signed_in", email: "owner@example.com", services: ["gmail", "drive"], write: ["drive"])
