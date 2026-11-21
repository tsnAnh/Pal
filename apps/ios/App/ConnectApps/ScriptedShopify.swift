import Foundation
import PalConnect
import PalProtocol
import PalTransport

enum ShopifyScript {
    static let argument = "-hermes-test-shopify"
    static let reachableAddress = "https://acme.myshopify.com/api/mcp"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func wrap(_ rpc: any ConnectRPC) -> any ConnectRPC {
        isActive ? ScriptedShopifyRPC(base: rpc) : rpc
    }
}

actor ScriptedShopifyRPC: ConnectRPC {
    private let base: any ConnectRPC
    private var saved: String?

    init(base: any ConnectRPC) {
        self.base = base
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard params["name"]?.stringValue == ShopifyConnector.slug else { return try await base.call(method, params) }
        switch method {
        case "mcp.servers.add", "mcp.servers.update":
            saved = params["config"]?["url"]?.stringValue
            return ["ok": true]
        case "mcp.servers.test":
            return saved == ShopifyScript.reachableAddress ? ["ok": true] : ["ok": false, "reason": "unreachable"]
        case "mcp.servers.remove":
            saved = nil
            return ["ok": true]
        default:
            return try await base.call(method, params)
        }
    }
}
