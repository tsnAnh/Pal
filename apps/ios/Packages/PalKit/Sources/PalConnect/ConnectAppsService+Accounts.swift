import Foundation
import PalProtocol
import PalTransport

extension ConnectAppsService {
    func removalParams(_ name: String, account: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let account { params["account"] = .string(account) }
        return params
    }

    public func renameAccount(_ app: ConnectApp, from account: String, to newName: String) async throws {
        let others = app.accountNames.filter { $0 != account }
        let taken = others + (newName == account ? [account] : [])
        if let problem = ConnectorAccountName.validate(newName, existing: taken) { throw ConnectAppsError.accountName(problem) }
        let name: String
        switch app.source {
        case .catalog(let entry): name = entry.slug
        case .mcp(let preset, _): name = preset
        case .custom, .googleWorkspace: throw ConnectAppsError.unavailable
        }
        do {
            _ = try await rawCall("mcp.servers.accounts.rename", ["name": .string(name), "account": .string(account), "new_account": .string(newName)])
        } catch let error as GatewayTransportError {
            if case .rpc(let rpc) = error, rpc.code == Self.accountExistsCode { throw ConnectAppsError.accountName(.taken) }
            throw Self.map(error, method: "mcp.servers.accounts.rename")
        }
    }

    func storeCatalogAccountToken(_ entry: PalCatalogEntry, token: String, account: ConnectorAccountTarget) async throws {
        let added = try await addCatalogServer(entry)
        do {
            try await setApiKey(name: entry.slug, value: token, envVar: nil, account: account, create: account.create)
        } catch {
            if added { _ = try? await call("mcp.servers.remove", ["name": .string(entry.slug)]) }
            throw error
        }
    }

    func setApiKey(name: String, value: String, envVar: String?, account: ConnectorAccountTarget?, create: Bool) async throws {
        var params: [String: JSONValue] = ["name": .string(name), "value": .string(value)]
        if let account {
            params = account.scoping(params, create: create)
        } else if let envVar {
            params["env_var"] = .string(envVar)
        }
        do {
            _ = try await rawCall("mcp.servers.set_api_key", params)
        } catch let error as GatewayTransportError {
            if case .rpc(let rpc) = error, rpc.code == Self.accountExistsCode { throw ConnectAppsError.accountName(.taken) }
            throw Self.map(error, method: "mcp.servers.set_api_key")
        }
    }
}
