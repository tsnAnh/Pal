import Foundation
import HermesDiagnostics
import HermesProtocol

public enum CustomConnectorStage: Sendable, Equatable {
    case saved
}

public typealias CustomConnectorProgress = @MainActor @Sendable (CustomConnectorStage) -> Void

extension ConnectAppsService {
    private func customCall(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        do {
            return try await rawCall(method, params)
        } catch {
            let failure = ConnectorFailure.from(error)
            diagnostics.info("connect", "custom connector \(method) failed: \(Diagnostics.describe(error))")
            throw failure
        }
    }

    private static func configParams(_ connector: ValidatedConnector) -> JSONValue {
        ["url": .string(connector.url), "transport": .string(connector.transport.rawValue)]
    }

    public func addCustomConnector(
        _ draft: CustomConnectorDraft,
        progress: CustomConnectorProgress = { _ in }
    ) async throws -> [ConnectorTool] {
        let connector: ValidatedConnector
        do { connector = try draft.validated() } catch { throw ConnectorFailure.validation(error) }
        var params: [String: JSONValue] = ["name": .string(connector.name), "config": Self.configParams(connector)]
        if let token = connector.token { params["bearer_token"] = .string(token.value) }
        _ = try await customCall("mcp.servers.add", params)
        await progress(.saved)
        do {
            if connector.auth == .oauth { try await authorizeCustom(name: connector.name) }
            return try await testCustomConnector(name: connector.name)
        } catch {
            await removeQuietly(connector.name)
            throw ConnectorFailure.from(error)
        }
    }

    public func updateCustomConnector(
        _ draft: CustomConnectorDraft,
        progress: CustomConnectorProgress = { _ in }
    ) async throws -> [ConnectorTool] {
        let connector: ValidatedConnector
        do { connector = try draft.validated() } catch { throw ConnectorFailure.validation(error) }
        var params: [String: JSONValue] = [
            "name": .string(connector.name), "config": Self.configParams(connector), "auth": .string(connector.auth.rawValue),
        ]
        if let token = connector.token { params["bearer_token"] = .string(token.value) }
        _ = try await customCall("mcp.servers.update", params)
        await progress(.saved)
        if connector.auth == .oauth, draft.originalAuth != .oauth { try await authorizeCustom(name: connector.name) }
        return try await testCustomConnector(name: connector.name)
    }

    public func testCustomConnector(name: String) async throws -> [ConnectorTool] {
        let result = try await customCall("mcp.servers.test", ["name": .string(name)])
        if let failure = ConnectorFailure.evaluate(testResult: result) { throw failure }
        return ConnectorFailure.tools(from: result)
    }

    public func removeCustomConnector(name: String) async throws {
        _ = try await customCall("mcp.servers.remove", ["name": .string(name)])
    }

    public func enabledCustomConnectors(forBot bot: String) async throws -> Set<String> {
        let description = try await customCall("profiles.describe", ["name": .string(bot)])
        let rows = description["mcp_servers"]?.arrayValue ?? []
        return Set(rows.compactMap { row in
            row["enabled"]?.boolValue == true ? row["name"]?.stringValue : nil
        })
    }

    public func setCustomConnector(_ name: String, enabled: Bool, forBot bot: String) async throws {
        var names = try await enabledCustomConnectors(forBot: bot)
        if enabled { names.insert(name) } else { names.remove(name) }
        _ = try await customCall("profiles.configure", [
            "name": .string(bot), "enabled_mcp_servers": .array(names.sorted().map { .string($0) }),
        ])
    }

    private func authorizeCustom(name: String) async throws {
        do {
            try await authorizeMcp(name: name, browser: systemBrowser)
        } catch let error as ConnectAppsError {
            throw error == .cancelled ? ConnectorFailure.signInCancelled : ConnectorFailure.authRefused
        } catch {
            throw ConnectorFailure.from(error)
        }
    }

    private func removeQuietly(_ name: String) async {
        let service = self
        await Task { _ = try? await service.rawCall("mcp.servers.remove", ["name": .string(name)]) }.value
    }
}
