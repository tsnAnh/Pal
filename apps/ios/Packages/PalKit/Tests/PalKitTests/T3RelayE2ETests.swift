import Foundation
import PalAuth
import PalChat
import PalClient
import PalDevice
import PalProtocol
import PalREST
import PalT3Code
import PalTransport
import Synchronization
import Testing

private let projectList = "mcp__t3code__t3_project_list"
private let threadList = "mcp__t3code__t3_thread_list"
private func messageText(_ message: WireMessage) -> String {
    if let text = message.text, !text.isEmpty { return text }
    if let text = message.content?.stringValue { return text }
    return (message.content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined()
}

private func jsonEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

private let threadArguments = #"{"allProjects": true}"#
private let resultPrefix = "call-tool-result "

private struct AgentTurn {
    var reply: String

    var toolResult: String? {
        reply.hasPrefix(resultPrefix) ? String(reply.dropFirst(resultPrefix.count)) : nil
    }

    var excerpt: String {
        guard let result = toolResult else { return reply }
        let parts = result.components(separatedBy: "\n\n")
        let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\n\n") : result
        return body.replacingOccurrences(of: "\n</untrusted_tool_result>", with: "")
    }

    var discovered: Bool { toolResult != nil }
    var answered: Bool { toolResult.map { !$0.contains("\"error\"") } ?? false }
}

@MainActor
private final class RelayRig {
    let gateway: LiveGateway
    let environment: E2EEnvironment
    let steps: RelayStepLog
    let control: RelayControl
    let locator: T3Locator
    let tokens = InMemoryT3TokenStore()
    let bridge: T3McpBridge
    let transport = RecordingTransport()
    let auth: AuthSession
    let presence: ReachPresence
    let macLog = RelayMacLog(file: RelayE2E.macLogFile)
    let frames: RelayFrameLog
    let chatClient: PalClient
    let device = FakeDevice()
    let pairingCode: RelayPairingCode
    let profiles: [String]
    var stacks: [String: DeviceToolStack] = [:]
    var controller: T3CodeController!
    var watching: Task<Void, Never>?
    var portBeforeStop: Int?

    static let defaultProfile = "default"

    init() async throws {
        let gateway = try #require(LiveGateway.fromEnvironment())
        let environment = try #require(E2EEnvironment.fromEnvironment())
        self.gateway = gateway
        self.environment = environment
        frames = RelayFrameLog(macLog: macLog)
        steps = RelayStepLog(file: try #require(RelayE2E.stepsFile))
        control = RelayControl(directory: try #require(RelayE2E.controlDirectory))
        locator = T3Locator.standard(baseDirectory: URL(fileURLWithPath: try #require(RealT3.baseDirectory), isDirectory: true))
        bridge = T3McpBridge(locator: locator, tokens: tokens, diagnostics: macLog.diagnostics)
        pairingCode = RelayPairingCode(try #require(RealT3.pairingCode))
        profiles = [Self.defaultProfile] + environment.profiles
        let browser = ProgrammaticBrowser(username: gateway.username, password: gateway.password)
        let credentials = try await NativeSignIn(transport: transport).signIn(baseURL: gateway.baseURL, browser: browser)
        auth = try AuthSession(store: InMemoryCredentialStore(), transport: transport)
        try await auth.adopt(credentials)
        presence = ReachPresence(identity: DeviceIdentity(deviceID: UUID().uuidString, formFactor: .mac, appVersion: "t3code-relay-e2e"))
        chatClient = PalClient(auth: auth, transport: transport)
    }

    func step(_ name: String, _ body: () async throws -> (pass: Bool, observed: JSONValue)) async throws {
        do {
            let outcome = try await body()
            steps.record(name, pass: outcome.pass, observed: outcome.observed)
            if !outcome.pass {
                Issue.record("step failed: \(name) \(outcome.observed)")
                throw RelayStepFailed(name: name)
            }
        } catch let failed as RelayStepFailed {
            throw failed
        } catch {
            steps.record(name, pass: false, observed: ["error": .string(clipped(String(describing: error)))])
            Issue.record("step threw: \(name) \(error)")
            throw RelayStepFailed(name: name)
        }
    }

    func wireProfile(_ key: String) -> String? { key == Self.defaultProfile ? nil : key }

    func configText(_ key: String) -> String {
        let path = key == Self.defaultProfile
            ? environment.home.appending(path: "config.yaml")
            : environment.home.appending(path: "profiles/\(key)/config.yaml")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    func makeStack(_ key: String) -> DeviceToolStack {
        let client = PalClient(
            auth: auth, transport: transport,
            dialOptions: GatewayDialOptions(frameTap: frames.tap(profile: key)), presence: presence
        )
        let wire = wireProfile(key)
        return DeviceToolStack.make(
            connect: { try await client.connect(profile: wire, reach: .deviceHost) },
            providers: DeviceProviders(calendar: device, reminders: device, contacts: device, location: device, alarms: device, home: device),
            permissions: FakePermissions(),
            consent: FakeConsent(),
            diagnostics: macLog.diagnostics,
            mcpRelay: bridge
        )
    }

    func startHosts() async {
        for key in profiles {
            let stack = makeStack(key)
            stacks[key] = stack
            await stack.host.start()
        }
    }

    func startWatching() {
        guard watching == nil else { return }
        let target = controller
        watching = Task { await target?.watch() }
    }

    func stopWatching() {
        watching?.cancel()
        watching = nil
    }

    func stopHosts() async {
        let running = Array(stacks.values)
        stacks.removeAll()
        for stack in running { await stack.host.stop() }
    }

    func allHostsConnected() async -> Bool {
        for stack in stacks.values where !(await stack.host.hasConnection) { return false }
        return !stacks.isEmpty
    }

    func makeController() {
        let locator = locator
        let code = pairingCode
        let registrar = T3HostRegistrar { [self] in await MainActor.run { Array(self.stacks.values.map(\.host)) } }
        controller = T3CodeController(
            locator: locator, tokens: tokens,
            authorizer: T3OAuthAuthorizer(
                browser: ApprovingBrowser(origin: { locator.runtime()?.origin ?? URL(string: "http://127.0.0.1:1")! }, pairingCode: { code.current }),
                callbackTimeout: .seconds(45)
            ),
            registrar: registrar,
            bridge: bridge,
            diagnostics: macLog.diagnostics
        )
        let target = controller
        Task { await bridge.observeUnauthorized { await MainActor.run { target?.unauthorized() } } }
    }

    func agentCall(_ key: String, tool: String, arguments: String = "{}") async throws -> AgentTurn {
        let connection = try await chatClient.connect(profile: wireProfile(key))
        defer { Task { await connection.close() } }
        let api = SessionAPI(connection: connection, profile: key)
        let prompt = "CALL-TOOL \(tool) \(arguments)"
        let snapshot = try await api.create(title: "t3-relay-\(UUID().uuidString.prefix(8))", requestID: UUID().uuidString, hidden: false)
        _ = try await api.submit(sessionID: snapshot.sessionID, text: prompt, submissionID: UUID().uuidString)
        var reply = ""
        var lastRoles = ""
        let settled = await pollUntil(.seconds(60), interval: .milliseconds(400)) {
            guard let current = try? await api.resume(sessionID: snapshot.sessionID) else { return false }
            lastRoles = current.messages.map { "\($0.role):\(clipped(messageText($0), 80))" }.joined(separator: " | ") + " running=\(current.running)"
            guard !current.running else { return false }
            guard let message = current.messages.last(where: { $0.role == "assistant" && !messageText($0).isEmpty }) else { return false }
            reply = messageText(message)
            return true
        }
        guard settled else { throw RelayControlFailed(action: "agent turn", detail: "no reply within 60s: \(lastRoles)") }
        return AgentTurn(reply: reply)
    }

    func directText(of tool: String, arguments: JSONValue = [:]) async throws -> String {
        let recorder = RelayRecorder()
        let direct = T3McpBridge(locator: locator, tokens: tokens)
        func frame(_ message: JSONValue) -> DeviceMcpFrame { DeviceMcpFrame(relayID: "direct", server: .t3code, message: message) }
        await direct.relay(frame([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "pal-relay-e2e", "version": "1"]],
        ]), over: recorder.channel)
        let initialized = await awaitCondition { recorder.ids("direct") == [1] }
        guard initialized else { throw RelayControlFailed(action: "direct initialize", detail: "no answer") }
        await direct.relay(frame(["jsonrpc": "2.0", "method": "notifications/initialized"]), over: recorder.channel)
        await direct.relay(frame([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments],
        ]), over: recorder.channel)
        let answered = await awaitCondition(.seconds(30)) { recorder.ids("direct") == [1, 2] }
        guard answered else {
            throw RelayControlFailed(action: "direct call", detail: "no answer")
        }
        await direct.close(DeviceMcpClose(relayID: "direct", reason: .clientClosed))
        let content = recorder.deliveries[1].message["result"]?["content"]?.arrayValue ?? []
        return content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    func registerCount(_ key: String) -> Int {
        frames.outboundCalls(DeviceMcpWire.registerMethod, profile: key).count
    }

    func waitForTools(_ key: String) async throws -> AgentTurn {
        var last = AgentTurn(reply: "")
        _ = await pollUntil(.seconds(90), interval: .seconds(1)) {
            guard let turn = try? await self.agentCall(key, tool: projectList) else { return false }
            last = turn
            return turn.answered
        }
        return last
    }

    func recovers(_ key: String, within timeout: Duration = .seconds(120)) async -> AgentTurn? {
        var found: AgentTurn?
        _ = await pollUntil(timeout, interval: .seconds(2)) {
            guard let turn = try? await self.agentCall(key, tool: projectList), turn.answered else { return false }
            found = turn
            return true
        }
        return found
    }
}

private func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

@MainActor
@Suite("T3 relay across the real gateway and the real T3 Code server", .enabled(if: RelayE2E.enabled), .serialized)
struct T3RelayE2ETests {
    @Test func theBotReachesT3ThroughTheMacRelayAndEveryFailureIsReportedHonestly() async throws {
        let rig = try await RelayRig()
        do {
            try await run(rig)
        } catch {
            rig.stopWatching()
            await rig.stopHosts()
            await rig.bridge.closeAll()
            throw error
        }
        rig.stopWatching()
        await rig.stopHosts()
        await rig.bridge.closeAll()
    }

    private func run(_ rig: RelayRig) async throws {
        try await rig.step("gateway.sign-in") {
            let stored = await rig.auth.baseURL
            return (stored != nil, ["profiles": strings(rig.profiles)])
        }

        try await rig.step("mac.hosts-connect-on-every-profile") {
            await rig.startHosts()
            let connected = await pollUntil(.seconds(60)) { await rig.allHostsConnected() }
            let hellos = rig.profiles.map { profile -> JSONValue in
                let params = rig.frames.outboundCalls("client.hello", profile: profile).first?["params"]
                return [
                    "profile": .string(profile), "kind": params?["kind"] ?? .null,
                    "device_tools": params?["capabilities"] ?? params?["device_tools"] ?? .null,
                ]
            }
            let macKinds = hellos.allSatisfy { $0["kind"]?.stringValue == "mac" }
            return (connected && macKinds, ["hellos": .array(hellos)])
        }

        try await rig.step("t3.oauth-sign-in-and-registration") {
            rig.makeController()
            await rig.controller.refresh()
            let before = rig.controller.connection
            await rig.controller.connect()
            let connected = rig.controller.connection == .connected
            let token = try rig.tokens.load()
            let counts = rig.profiles.map { rig.registerCount($0) }
            return (
                before == .signedOut && connected && token != nil && counts.allSatisfy { $0 == 1 },
                ["before": .string(String(describing: before)), "after": .string(String(describing: rig.controller.connection)),
                 "register_calls": .array(counts.map { .int($0) }), "token_has_expiry": .bool(token?.expiresAt != nil)]
            )
        }

        try await rig.step("gateway.registration-persisted-per-profile") {
            let deviceID = await rig.presence.deviceID
            let rows = rig.profiles.map { profile -> JSONValue in
                let text = rig.configText(profile)
                return ["profile": .string(profile), "bound_to_this_mac": .bool(text.contains("device_id: \(deviceID)") && text.contains("transport: device"))]
            }
            return (rows.allSatisfy { $0["bound_to_this_mac"]?.boolValue == true }, ["profiles": .array(rows)])
        }

        var alpha = AgentTurn(reply: "")
        try await rig.step("gateway.agent-discovers-t3-tools") {
            alpha = try await rig.waitForTools(rig.profiles[1])
            let threads = try await rig.agentCall(rig.profiles[1], tool: threadList, arguments: threadArguments)
            return (
                alpha.discovered && threads.discovered,
                ["profile": .string(rig.profiles[1]), "project_list_discovered": .bool(alpha.discovered), "thread_list_discovered": .bool(threads.discovered)]
            )
        }

        try await rig.step("agent.project-list-returns-t3-response-through-relay") {
            let direct = try await rig.directText(of: "t3_project_list")
            let result = try #require(alpha.toolResult)
            return (
                !direct.isEmpty && result.contains(jsonEscaped(direct)),
                ["direct_t3_text": .string(clipped(direct)), "agent_saw": .string(clipped(AgentTurn(reply: resultPrefix + result).excerpt))]
            )
        }

        try await rig.step("agent.thread-list-returns-t3-response-through-relay") {
            let direct = try await rig.directText(of: "t3_thread_list", arguments: ["allProjects": true])
            let turn = try await rig.agentCall(rig.profiles[1], tool: threadList, arguments: threadArguments)
            let result = try #require(turn.toolResult)
            return (
                !direct.isEmpty && result.contains(jsonEscaped(direct)),
                ["direct_t3_text": .string(clipped(direct)), "agent_saw": .string(clipped(AgentTurn(reply: resultPrefix + result).excerpt))]
            )
        }

        try await rig.step("multiplex.every-profile-gets-the-tools-and-answers") {
            var rows: [JSONValue] = []
            var ok = true
            for profile in rig.profiles {
                let turn = try await rig.waitForTools(profile)
                ok = ok && turn.answered
                rows.append(["profile": .string(profile), "discovered": .bool(turn.discovered), "answered": .bool(turn.answered)])
            }
            return (ok, ["profiles": .array(rows)])
        }

        try await rig.step("multiplex.relays-are-separate-per-profile-connection") {
            let perProfile = rig.profiles.map { profile in
                Set(rig.frames.inboundEvents(DeviceMcpFrame.eventType, profile: profile).compactMap { $0["relay_id"]?.stringValue })
            }
            let union = perProfile.reduce(into: Set<String>()) { $0.formUnion($1) }
            let disjoint = union.count == perProfile.map(\.count).reduce(0, +)
            return (
                disjoint && perProfile.allSatisfy { !$0.isEmpty },
                ["relays_per_profile": .array(perProfile.map { .int($0.count) }), "disjoint": .bool(disjoint),
                 "open_relays_on_mac": .int(await rig.bridge.openRelayCount)]
            )
        }

        try await rig.step("multiplex.concurrent-calls-from-all-profiles") {
            let outcomes = await withTaskGroup(of: (String, Bool).self) { group in
                for profile in rig.profiles {
                    group.addTask {
                        let turn = try? await rig.agentCall(profile, tool: projectList)
                        return (profile, turn?.answered ?? false)
                    }
                }
                var collected: [(String, Bool)] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            return (outcomes.allSatisfy(\.1), ["answered": .array(outcomes.sorted { $0.0 < $1.0 }.map { ["profile": .string($0.0), "ok": .bool($0.1)] })])
        }

        try await rig.step("multiplex.unregistering-one-profile-leaves-the-others") {
            let target = rig.profiles[1], other = rig.profiles[2]
            try await rig.stacks[target]!.host.unregisterMcp(.t3code)
            let goneForTarget = await pollUntil(.seconds(60), interval: .seconds(1)) {
                guard let turn = try? await rig.agentCall(target, tool: projectList) else { return false }
                return !turn.discovered
            }
            let otherTurn = try await rig.agentCall(other, tool: projectList)
            let otherOK = otherTurn.answered
            _ = try await rig.stacks[target]!.host.registerMcp(.t3code)
            let back = try await rig.waitForTools(target)
            return (
                goneForTarget && otherOK && back.answered,
                ["unregistered_profile_lost_tools": .bool(goneForTarget), "other_profile_kept_tools": .bool(otherOK),
                 "reregistered_profile_has_tools": .bool(back.answered)]
            )
        }

        try await rig.step("failure.t3-stopped-reports-unreachable") {
            rig.portBeforeStop = rig.locator.runtime()?.origin.port
            try await rig.control.request("t3.stop")
            let turn = try await rig.agentCall(rig.profiles[1], tool: projectList)
            return (
                turn.toolResult != nil && !turn.answered && turn.reply.contains("T3 Code isn't running on this Mac"),
                ["agent_saw": .string(clipped(turn.excerpt))]
            )
        }

        try await rig.step("failure.t3-restart-on-new-port-recovers-when-the-mac-notices") {
            let oldPort = rig.portBeforeStop
            let registersBefore = rig.profiles.map { rig.registerCount($0) }
            rig.startWatching()
            let started = try await rig.control.request("t3.start")
            let newPort = rig.locator.runtime()?.origin.port
            let turn = await rig.recovers(rig.profiles[1])
            let registersAfter = rig.profiles.map { rig.registerCount($0) }
            return (
                turn != nil && newPort != nil && newPort != oldPort && registersAfter == registersBefore.map { $0 + 1 },
                ["old_port": .int(oldPort ?? 0), "new_port": .int(newPort ?? 0), "harness": started["detail"] ?? .null,
                 "register_calls_before": .array(registersBefore.map { .int($0) }), "register_calls_after": .array(registersAfter.map { .int($0) }),
                 "agent_saw": .string(clipped(turn?.excerpt ?? "no recovery"))]
            )
        }

        try await rig.step("failure.revoked-token-asks-the-owner-to-sign-in") {
            try await rig.control.request("t3.revoke")
            let inFlight = try await rig.agentCall(rig.profiles[1], tool: projectList)
            let next = try await rig.agentCall(rig.profiles[1], tool: projectList)
            _ = await pollUntil(.seconds(10)) { rig.controller.connection != .connected }
            let firstSaidWhy = (inFlight.toolResult ?? "").contains("Sign in to T3 Code again")
            let nextIsTyped = (next.toolResult ?? "").contains("auth_required") && (next.toolResult ?? "").contains("mcp:t3code")
            return (
                firstSaidWhy && nextIsTyped,
                ["first_call": .string(clipped(inFlight.excerpt)), "next_call": .string(clipped(next.excerpt)),
                 "mac_state": .string(String(describing: rig.controller.connection))]
            )
        }

        try await rig.step("failure.signing-in-again-restores-the-tools") {
            let code = try await rig.control.request("t3.pairing")
            rig.pairingCode.replace(code["detail"]?.stringValue ?? "")
            await rig.controller.connect()
            let turn = await rig.recovers(rig.profiles[1])
            return (
                turn != nil && rig.controller.connection == .connected,
                ["mac_state": .string(String(describing: rig.controller.connection)), "agent_saw": .string(clipped(turn?.excerpt ?? "no recovery"))]
            )
        }

        try await rig.step("failure.mac-disconnect-goes-offline-and-reconnect-restores-tools") {
            let registersBefore = rig.profiles.map { rig.registerCount($0) }
            await rig.stopHosts()
            let offline = try await rig.agentCall(rig.profiles[1], tool: projectList)
            let text = offline.reply.lowercased()
            let reportedOffline = text.contains("offline") || text.contains("disconnected") || text.contains("cannot reach")
            await rig.startHosts()
            let connected = await pollUntil(.seconds(60)) { await rig.allHostsConnected() }
            let turn = await rig.recovers(rig.profiles[1])
            let registersAfter = rig.profiles.map { rig.registerCount($0) }
            return (
                reportedOffline && connected && turn != nil,
                ["while_disconnected": .string(clipped(offline.excerpt)), "after_reconnect": .string(clipped(turn?.excerpt ?? "no recovery")),
                 "register_calls_before": .array(registersBefore.map { .int($0) }), "register_calls_after": .array(registersAfter.map { .int($0) })]
            )
        }
    }
}
