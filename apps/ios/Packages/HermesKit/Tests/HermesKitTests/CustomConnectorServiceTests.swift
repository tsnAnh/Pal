import Foundation
import HermesAuth
import HermesConnect
import HermesDiagnostics
import HermesProtocol
import HermesTransport
import Synchronization
import Testing

@Suite("Custom connector service")
struct CustomConnectorServiceTests {
    private func draft(
        type: CustomConnectorType = .remoteHTTPS, headers: [ConnectorHeader] = [], clientID: String = "", originalHeaderKeys: [String] = []
    ) -> CustomConnectorDraft {
        CustomConnectorDraft(
            name: "notes", type: type, url: "https://mcp.example.com/mcp", headers: headers, clientID: clientID, originalHeaderKeys: originalHeaderKeys
        )
    }

    private func failure<T>(_ work: () async throws -> T) async -> ConnectorFailure? {
        do { _ = try await work(); return nil } catch { return error as? ConnectorFailure }
    }

    private func testFailure(_ reply: JSONValue) async -> ConnectorFailure? {
        let rpc = CustomRPC(["mcp.servers.test": { _ in reply }])
        return await failure { try await customService(rpc).testCustomConnector(name: "notes") }
    }

    @Test func addSendsTheConfigHeadersAndClientID() async throws {
        let secret = randomSecret()
        let clientID = "client-" + UUID().uuidString
        let rpc = CustomRPC(["mcp.servers.add": { _ in ["ok": true] }, "mcp.servers.test": okTools(["search", "fetch"])])
        let stages = Mutex<[CustomConnectorStage]>([])
        let rows = [ConnectorHeader(key: "Authorization", value: "Bearer " + secret), ConnectorHeader()]
        let tools = try await customService(rpc, profile: "work").addCustomConnector(draft(headers: rows, clientID: clientID)) { stage in stages.withLock { $0.append(stage) } }
        #expect(tools.map(\.name) == ["search", "fetch"] && tools[0].description == "Does search")
        #expect(stages.withLock { $0 } == [.saved])
        let add = try #require(rpc.params("mcp.servers.add").first)
        #expect(add["name"]?.stringValue == "notes")
        #expect(add["config"]?["url"]?.stringValue == "https://mcp.example.com/mcp")
        #expect(add["config"]?["transport"]?.stringValue == "http")
        #expect(add["headers"]?["Authorization"]?.stringValue == "Bearer " + secret)
        #expect(add["client_id"]?.stringValue == clientID)
        #expect(add["profile"]?.stringValue == "work")
        #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test"])
    }

    @Test func addWithoutHeadersOrClientIDOmitsThem() async throws {
        let rpc = CustomRPC(["mcp.servers.add": { _ in ["ok": true] }, "mcp.servers.test": okTools(["a"])])
        _ = try await customService(rpc).addCustomConnector(draft(type: .remoteSSE, headers: [ConnectorHeader()]))
        let add = try #require(rpc.params("mcp.servers.add").first)
        #expect(add["headers"] == nil && add["client_id"] == nil)
        #expect(add["config"]?["transport"]?.stringValue == "sse")
    }

    @Test func invalidDraftsNeverReachTheGateway() async {
        let rpc = CustomRPC([:])
        let bad = CustomConnectorDraft(name: "x", url: "http://example.com")
        #expect(await failure { try await customService(rpc).addCustomConnector(bad) } == .validation(.insecureURL))
        let noValue = draft(headers: [ConnectorHeader(key: "X-Key")])
        #expect(await failure { try await customService(rpc).addCustomConnector(noValue) } == .validation(.invalidHeader))
        #expect(rpc.methods().isEmpty)
    }

    @Test func testResultsMapToPlainFailures() async {
        #expect(await testFailure(["ok": false, "reason": "unreachable", "error": "boom"]) == .unreachable)
        #expect(await testFailure(["ok": false, "reason": "auth_refused"]) == .authRefused)
        #expect(await testFailure(["ok": false, "reason": "server_error"]) == .serverError)
        #expect(await testFailure(["ok": false, "error": "HTTP 401 Unauthorized"]) == .authRefused)
        #expect(await testFailure(["ok": false, "error": "connection refused"]) == .unreachable)
        #expect(await testFailure(["ok": false, "oauth_needed": true, "oauth_tokens_present": false]) == .authRefused)
        #expect(await testFailure(["ok": false, "error": "weird"]) == .serverError)
        #expect(await testFailure(["ok": false]) == .serverError)
        #expect(await testFailure(["ok": true, "tools": []]) == .noTools)
        #expect(await testFailure(["ok": true, "tools": [["name": "a", "description": "b"]]]) == nil)
    }

    @Test func rpcErrorsMapToPlainFailures() async {
        func add(_ reply: @escaping CustomRPC.Reply) async -> ConnectorFailure? {
            let rpc = CustomRPC(["mcp.servers.add": reply])
            return await failure { try await customService(rpc).addCustomConnector(draft()) }
        }
        #expect(await add(rpcFailure(4063, reason: "invalid_url")) == .invalidURL)
        #expect(await add(rpcFailure(4063, reason: "unsupported_transport")) == .unsupportedTransport)
        #expect(await add(rpcFailure(4063, message: "unsupported transport 'ws'")) == .unsupportedTransport)
        #expect(await add(rpcFailure(4090)) == .nameTaken)
        #expect(await add(rpcFailure(4001)) == .serverError)
        #expect(await add(rpcFailure(-32000)) == .serverError)
        #expect(await add({ _ in throw GatewayTransportError.timedOut }) == .offline)
        #expect(await add({ _ in throw URLError(.badServerResponse) }) == .serverError)
    }

    @Test func aFailedAddAfterSavingRemovesTheServerAgain() async {
        for reply in [["ok": false, "reason": "unreachable"], ["ok": true, "tools": []]] as [JSONValue] {
            let rpc = CustomRPC(["mcp.servers.add": { _ in ["ok": true] }, "mcp.servers.test": { _ in reply }, "mcp.servers.remove": { _ in ["ok": true] }])
            let result = await failure { try await customService(rpc).addCustomConnector(draft()) }
            #expect(result != nil)
            #expect(rpc.methods() == ["mcp.servers.add", "mcp.servers.test", "mcp.servers.remove"])
            #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "notes")
        }
    }

    @Test func aFailedAddThatNeverSavedLeavesNothingToRemove() async {
        let rpc = CustomRPC(["mcp.servers.add": rpcFailure(4090), "mcp.servers.remove": { _ in ["ok": true] }])
        _ = await failure { try await customService(rpc).addCustomConnector(draft()) }
        #expect(rpc.methods() == ["mcp.servers.add"])
    }

    @Test func updateKeepsStoredHeaderSecretsAndReplacesTheSet() async throws {
        let rpc = CustomRPC(["mcp.servers.update": { _ in ["ok": true] }, "mcp.servers.test": okTools(["a"])])
        let fresh = randomSecret()
        let rows = [ConnectorHeader(key: "X-Old", isStored: true), ConnectorHeader(key: "X-New", value: fresh), ConnectorHeader()]
        _ = try await customService(rpc).updateCustomConnector(draft(headers: rows, originalHeaderKeys: ["X-Old", "X-Gone"]))
        let first = try #require(rpc.params("mcp.servers.update").first)
        #expect(first["headers"]?["X-Old"] == JSONValue.null)
        #expect(first["headers"]?["X-New"]?.stringValue == fresh)
        #expect(first["headers"]?["X-Gone"] == nil)
        _ = try await customService(rpc).updateCustomConnector(draft(originalHeaderKeys: ["X-Old"]))
        #expect(rpc.params("mcp.servers.update").last?["headers"] == .object([:]))
        _ = try await customService(rpc).updateCustomConnector(draft())
        #expect(rpc.params("mcp.servers.update").last?["headers"] == nil)
    }

    @Test func aStoredHeaderTakesANewValueFromTheEditForm() async throws {
        let rpc = CustomRPC(["mcp.servers.update": { _ in ["ok": true] }, "mcp.servers.test": okTools(["a"])])
        let fresh = randomSecret()
        var stored = ConnectorHeader(key: "X-Old", isStored: true)
        stored.value = fresh
        _ = try await customService(rpc).updateCustomConnector(draft(headers: [stored], originalHeaderKeys: ["X-Old"]))
        let sent = try #require(rpc.params("mcp.servers.update").first)
        #expect(sent["headers"] == .object(["X-Old": .string(fresh)]))
    }

    @Test func removeCallsTheGateway() async throws {
        let rpc = CustomRPC(["mcp.servers.remove": { _ in ["ok": true] }])
        try await customService(rpc).removeCustomConnector(name: "notes")
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "notes")
    }

    @Test func togglingABotSendsTheFullReplacementList() async throws {
        let rpc = CustomRPC([
            "profiles.describe": { _ in ["mcp_servers": [["name": "linear", "enabled": true, "transport": "http"], ["name": "off", "enabled": false], ["name": "notes", "enabled": false]]] },
            "profiles.configure": { _ in ["ok": true] },
        ])
        try await customService(rpc).setCustomConnector("notes", enabled: true, forBot: "work")
        let on = try #require(rpc.params("profiles.configure").last)
        #expect(on["name"]?.stringValue == "work")
        #expect(on["enabled_mcp_servers"]?.arrayValue?.compactMap(\.stringValue) == ["linear", "notes"])
        try await customService(rpc).setCustomConnector("linear", enabled: false, forBot: "work")
        #expect(rpc.params("profiles.configure").last?["enabled_mcp_servers"]?.arrayValue?.compactMap(\.stringValue) == [])
        let enabled = try await customService(rpc).enabledCustomConnectors(forBot: "work")
        #expect(enabled == ["linear"])
    }

    @Test func headerValuesOnlyTravelAsTheHeadersParameterOfAddAndUpdate() async throws {
        let secrets = [randomSecret(), randomSecret()]
        let recorder = DiagnosticRecorder()
        let rpc = CustomRPC([
            "mcp.servers.add": { _ in ["ok": true] }, "mcp.servers.update": { _ in ["ok": true] },
            "mcp.servers.test": { _ in ["ok": false, "reason": "auth_refused", "error": "401"] },
            "mcp.servers.remove": { _ in ["ok": true] }, "profiles.describe": { _ in ["mcp_servers": []] }, "profiles.configure": { _ in ["ok": true] },
        ])
        let service = ConnectAppsService(rpc: rpc, profile: "work", browser: IdleBrowser(), systemBrowser: IdleBrowser(), diagnostics: recorder.diagnostics)
        let withSecrets = draft(headers: [ConnectorHeader(key: "Authorization", value: secrets[0]), ConnectorHeader(key: "X-Api-Key", value: secrets[1])])
        var strings: [String] = []
        do { _ = try await service.addCustomConnector(withSecrets) } catch { strings.append("\(error)"); strings.append(String(reflecting: error)) }
        do { _ = try await service.updateCustomConnector(withSecrets) } catch { strings.append("\(error)"); strings.append(String(describing: error)) }
        try await service.setCustomConnector("notes", enabled: true, forBot: "work")
        _ = try? await service.testCustomConnector(name: "notes")
        let failures: [ConnectorFailure] = [.unreachable, .authRefused, .noTools, .invalidURL, .unsupportedTransport, .serverError, .nameTaken, .offline, .signInCancelled, .validation(.invalidHeader), .validation(.duplicateHeader)]
        for failure in failures {
            strings.append(failure.message)
            strings.append("\(failure)")
        }
        strings.append(recorder.transcript)
        strings.append("\(withSecrets)")
        strings.append(String(reflecting: withSecrets))
        for header in withSecrets.headers { strings.append("\(header)"); strings.append(String(reflecting: header)) }
        var dumped = ""
        dump(withSecrets, to: &dumped)
        strings.append(dumped)
        for text in strings { for secret in secrets { #expect(!text.contains(secret)) } }
        for (method, params) in rpc.everything() {
            let encoded = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
            if method == "mcp.servers.add" || method == "mcp.servers.update" {
                #expect(params["headers"]?["Authorization"]?.stringValue == secrets[0])
                for secret in secrets { #expect(encoded.components(separatedBy: secret).count == 2) }
            } else {
                for secret in secrets { #expect(!encoded.contains(secret), "\(method)") }
            }
        }
    }

    @Test func customServersBecomeRowsWithoutPresetsAndWithoutASuggestion() {
        let servers = [
            McpServerEntry(name: "notes", url: "https://mcp.example.com/mcp", transport: "sse", enabled: true, headers: ["Authorization"], clientID: "abc"),
            McpServerEntry(name: "linear", url: "https://mcp.linear.app/mcp"),
            McpServerEntry(name: "stdio-only", url: nil),
            McpServerEntry(name: "paused", url: "https://p.example.com/mcp", enabled: false),
        ]
        let catalog = ConnectCatalog.make(hosted: [], states: [], mcp: [McpPresetEntry(name: "linear", description: "Issues", installed: true, enabled: true)], servers: servers)
        let custom = catalog.apps.filter { if case .custom = $0.source { true } else { false } }
        #expect(custom.map(\.name) == ["notes", "paused"])
        #expect(custom.map(\.category) == [ConnectCatalog.customCategory, ConnectCatalog.customCategory])
        #expect(custom.map(\.state) == [.connected, .disconnected])
        #expect(custom[0].source == .custom(CustomConnectorInfo(name: "notes", url: "https://mcp.example.com/mcp", type: .remoteSSE, headerKeys: ["Authorization"], clientID: "abc")))
        #expect(custom[1].source == .custom(CustomConnectorInfo(name: "paused", url: "https://p.example.com/mcp")))
    }

    @Test func serverEntriesDecodeHeaderNamesDefensively() throws {
        func decode(_ json: String) throws -> McpServerEntry { try JSONDecoder().decode(McpServerEntry.self, from: Data(json.utf8)) }
        let full = try decode(#"{"name":"n","url":"https://a.example.com","transport":"http","headers":["Authorization","X-Key"],"client_id":"cid"}"#)
        #expect(full.headers == ["Authorization", "X-Key"] && full.clientID == "cid")
        let bare = try decode(#"{"name":"n","url":"https://a.example.com"}"#)
        #expect(bare.headers.isEmpty && bare.clientID == nil && bare.enabled)
        let odd = try decode(#"{"name":"n","url":"https://a.example.com","headers":{"Authorization":"x"},"client_id":7}"#)
        #expect(odd.headers.isEmpty && odd.clientID == nil)
    }

    @Test func oauthChallengeStartsSignInInTheSystemBrowserWithTheClientID() async throws {
        let clientID = "client-" + UUID().uuidString
        let rpc = CustomRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.oauth.start": { _ in ["session_id": "s1", "auth_url": "https://auth.example.com/authorize"] },
            "mcp.servers.oauth.callback": { _ in ["ok": true] },
            "mcp.servers.oauth.poll": { _ in ["status": "approved"] },
            "mcp.servers.test": oauthThenTools(["a"]),
        ])
        let system = RedirectingBrowser(rpc: rpc)
        let catalog = RecordingBrowser()
        let tools = try await customService(rpc, system: system, catalog: catalog).addCustomConnector(draft(clientID: clientID))
        #expect(tools.map(\.name) == ["a"])
        #expect(system.presented.withLock { $0 }.map(\.host) == ["auth.example.com"])
        #expect(catalog.presented.withLock { $0 }.isEmpty)
        #expect(rpc.params("mcp.servers.oauth.start").first?["client_id"]?.stringValue == clientID)
        #expect(rpc.params("mcp.servers.oauth.callback").first?["code"]?.stringValue == "granted")
        #expect(rpc.methods().filter { $0 == "mcp.servers.test" }.count == 2)
    }

    @Test func noChallengeMeansNoSignIn() async throws {
        let rpc = CustomRPC(["mcp.servers.add": { _ in ["ok": true] }, "mcp.servers.test": okTools(["a"])])
        _ = try await customService(rpc).addCustomConnector(draft())
        #expect(!rpc.methods().contains { $0.hasPrefix("mcp.servers.oauth") })
    }

    @Test func aCancelledSignInRemovesTheServerAndReportsIt() async {
        let rpc = CustomRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.test": { _ in oauthChallenge() },
            "mcp.servers.oauth.start": { _ in ["session_id": "s1", "auth_url": "https://auth.example.com/authorize"] },
            "mcp.servers.oauth.cancel": { _ in ["ok": true] },
            "mcp.servers.remove": { _ in ["ok": true] },
        ])
        let result = await failure { try await customService(rpc, system: IdleBrowser()).addCustomConnector(draft()) }
        #expect(result == .signInCancelled)
        #expect(rpc.methods().last == "mcp.servers.remove")
    }

    @Test func cancellingTheTaskMidSignInRemovesTheHalfAddedServer() async throws {
        let rpc = CustomRPC([
            "mcp.servers.add": { _ in ["ok": true] },
            "mcp.servers.test": { _ in oauthChallenge() },
            "mcp.servers.oauth.start": { _ in ["session_id": "s1", "auth_url": "https://auth.example.com/authorize"] },
            "mcp.servers.oauth.cancel": { _ in ["ok": true] },
            "mcp.servers.remove": { _ in ["ok": true] },
        ])
        let browser = BlockingBrowser()
        let service = customService(rpc, system: browser)
        let value = draft()
        let task = Task { try await service.addCustomConnector(value) }
        for _ in 0..<400 where browser.presented.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!browser.presented.withLock { $0.isEmpty })
        task.cancel()
        _ = await task.result
        #expect(rpc.methods().last == "mcp.servers.remove")
        #expect(rpc.params("mcp.servers.remove").first?["name"]?.stringValue == "notes")
    }
}

final class RedirectingBrowser: AuthorizationBrowser {
    let presented = Mutex<[URL]>([])
    private let rpc: CustomRPC

    init(rpc: CustomRPC) { self.rpc = rpc }

    func present(_ url: URL) async throws {
        presented.withLock { $0.append(url) }
        guard let redirect = rpc.params("mcp.servers.oauth.start").first?["client_redirect_uri"]?.stringValue,
              var components = URLComponents(string: redirect)
        else { return }
        components.queryItems = [URLQueryItem(name: "code", value: "granted"), URLQueryItem(name: "state", value: "xyz")]
        if let target = components.url { _ = try await URLSession.shared.data(from: target) }
        try await Task.sleep(for: .seconds(30))
    }

    func dismiss() async {}
}
