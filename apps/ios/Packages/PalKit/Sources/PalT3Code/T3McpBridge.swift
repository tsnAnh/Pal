import Foundation
import PalDevice
import PalDiagnostics
import PalProtocol

public actor T3McpBridge: DeviceMcpRelay {
    public typealias Unauthorized = @Sendable () async -> Void

    private enum Phase {
        case idle
        case establishing
        case draining
        case ready
    }

    private enum Text {
        static let notRunning = "T3 Code isn't running on this Mac"
        static let signIn = "Sign in to T3 Code again"
        static let tooLarge = "That message was too large to pass along"
        static let ended = "T3 Code ended the connection"
        static let malformed = "That message couldn't be understood"
    }

    private final class Relay: @unchecked Sendable {
        let id: String
        let channel: DeviceMcpChannel
        let endpoint: URL
        let token: SecretString
        var phase = Phase.idle
        var sessionID: String?
        var held: [Data] = []
        var tasks: [UUID: Task<Void, Never>] = [:]
        var finished = false

        init(id: String, channel: DeviceMcpChannel, endpoint: URL, token: SecretString) {
            self.id = id
            self.channel = channel
            self.endpoint = endpoint
            self.token = token
        }
    }

    private struct Started {
        let bytes: URLSession.AsyncBytes
        let response: HTTPURLResponse
    }

    private let locator: T3Locator
    private let tokens: any T3TokenStore
    private let http: T3McpHTTP
    private let onUnauthorized: Unauthorized
    private let diagnostics: Diagnostics
    private var relays: [String: Relay] = [:]

    public init(
        locator: T3Locator,
        tokens: any T3TokenStore,
        diagnostics: Diagnostics = .silent,
        onUnauthorized: @escaping Unauthorized = {}
    ) {
        self.locator = locator
        self.tokens = tokens
        self.diagnostics = diagnostics
        self.onUnauthorized = onUnauthorized
        http = T3McpHTTP()
    }

    public func activeServers() async -> [DeviceMcpServer] {
        guard let token = try? tokens.load(), !token.isExpired(), locator.runtime() != nil else { return [] }
        return [.t3code]
    }

    public var openRelayCount: Int { relays.count }

    public func relay(_ frame: DeviceMcpFrame, over channel: DeviceMcpChannel) async {
        guard frame.server == .t3code else {
            await channel.fail(frame.relayID, .closed, Text.ended)
            return
        }
        guard case .object = frame.message, let body = try? JSONEncoder().encode(frame.message) else {
            await finish(relays[frame.relayID], channel: channel, relayID: frame.relayID, code: .closed, text: Text.malformed)
            return
        }
        guard body.count <= DeviceMcpLimits.maximumMessageBytes else {
            await finish(relays[frame.relayID], channel: channel, relayID: frame.relayID, code: .closed, text: Text.tooLarge)
            return
        }
        guard let relay = await relay(for: frame.relayID, channel: channel) else { return }
        switch relay.phase {
        case .idle:
            relay.phase = .establishing
            spawn(relay) { await $0.establish(relay, first: body) }
        case .establishing, .draining:
            relay.held.append(body)
        case .ready:
            spawn(relay) { await $0.send(relay, body) }
        }
    }

    public func close(_ close: DeviceMcpClose) async {
        guard let relay = relays.removeValue(forKey: close.relayID) else { return }
        retire(relay, deleteSession: true)
    }

    public func channelEnded(_ id: UUID) async {
        for relay in relays.values where relay.channel.id == id {
            relays.removeValue(forKey: relay.id)
            retire(relay, deleteSession: true)
        }
    }

    public func closeAll() {
        let open = Array(relays.values)
        relays.removeAll()
        for relay in open { retire(relay, deleteSession: true) }
    }

    private func relay(for id: String, channel: DeviceMcpChannel) async -> Relay? {
        if let existing = relays[id] { return existing }
        guard let runtime = locator.runtime() else {
            await channel.fail(id, .unreachable, Text.notRunning)
            return nil
        }
        guard let token = try? tokens.load(), !token.isExpired() else {
            await channel.fail(id, .authRequired, Text.signIn)
            await onUnauthorized()
            return nil
        }
        let relay = Relay(id: id, channel: channel, endpoint: runtime.mcpURL, token: token.access)
        relays[id] = relay
        return relay
    }

    private func spawn(_ relay: Relay, _ work: @escaping @Sendable (isolated T3McpBridge) async -> Void) {
        let taskID = UUID()
        relay.tasks[taskID] = Task { [weak self] in
            guard let self else { return }
            await work(self)
            await self.taskEnded(relay, taskID)
        }
    }

    private func taskEnded(_ relay: Relay, _ id: UUID) {
        relay.tasks.removeValue(forKey: id)
    }

    private func establish(_ relay: Relay, first: Data) async {
        guard let started = await begin(relay, body: first) else { return }
        relay.phase = .draining
        spawn(relay) { await $0.consume(started, for: relay) }
        while !relay.held.isEmpty, !relay.finished {
            let next = relay.held.removeFirst()
            guard let following = await begin(relay, body: next) else { return }
            spawn(relay) { await $0.consume(following, for: relay) }
        }
        if !relay.finished { relay.phase = .ready }
    }

    private func send(_ relay: Relay, _ body: Data) async {
        guard let started = await begin(relay, body: body) else { return }
        await consume(started, for: relay)
    }

    private func begin(_ relay: Relay, body: Data) async -> Started? {
        guard !relay.finished else { return nil }
        do {
            let (bytes, response) = try await http.post(relay.endpoint, body: body, token: relay.token, sessionID: relay.sessionID)
            guard !relay.finished else { return nil }
            if response.statusCode == 401 {
                await terminate(relay, code: .authRequired, text: Text.signIn)
                await onUnauthorized()
                return nil
            }
            if relay.sessionID == nil, let issued = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !issued.isEmpty {
                relay.sessionID = issued
            }
            return Started(bytes: bytes, response: response)
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            diagnostics.info("t3code", "request failed: \(Diagnostics.describe(error))")
            await terminate(relay, code: .unreachable, text: Text.notRunning)
            return nil
        }
    }

    private func consume(_ started: Started, for relay: Relay) async {
        let status = started.response.statusCode
        let contentType = started.response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        do {
            if (200..<300).contains(status) {
                if status == 202 || status == 204 {
                    for try await _ in started.bytes {}
                } else if contentType.hasPrefix("text/event-stream") {
                    try await streamEvents(started.bytes, for: relay)
                } else {
                    try await deliverBody(started.bytes, for: relay)
                }
            } else {
                try await rejected(started, for: relay)
            }
        } catch is CancellationError {
            return
        } catch is T3McpOversize {
            await terminate(relay, code: .closed, text: Text.tooLarge)
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            diagnostics.info("t3code", "response failed: \(Diagnostics.describe(error))")
            await terminate(relay, code: .unreachable, text: Text.notRunning)
        }
    }

    private func streamEvents(_ bytes: URLSession.AsyncBytes, for relay: Relay) async throws {
        var decoder = ServerSentEventDecoder(limit: DeviceMcpLimits.maximumMessageBytes)
        for try await byte in bytes {
            guard !relay.finished else { return }
            if let event = try decoder.feed(byte) { await deliver(event, for: relay) }
        }
    }

    private func deliverBody(_ bytes: URLSession.AsyncBytes, for relay: Relay) async throws {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > DeviceMcpLimits.maximumMessageBytes { throw T3McpOversize() }
        }
        guard !body.isEmpty, !relay.finished else { return }
        await deliver(body, for: relay)
    }

    private func rejected(_ started: Started, for relay: Relay) async throws {
        var body = Data()
        for try await byte in started.bytes {
            body.append(byte)
            if body.count > DeviceMcpLimits.maximumMessageBytes { throw T3McpOversize() }
        }
        if let message = try? JSONDecoder().decode(JSONValue.self, from: body), message["jsonrpc"] != nil {
            await deliver(body, for: relay)
            return
        }
        let gone = started.response.statusCode == 404 || (400..<500).contains(started.response.statusCode)
        await terminate(relay, code: gone ? .closed : .unreachable, text: gone ? Text.ended : Text.notRunning)
    }

    private func deliver(_ data: Data, for relay: Relay) async {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let messages: [JSONValue]
        switch value {
        case .object: messages = [value]
        case .array(let items): messages = items.filter { if case .object = $0 { true } else { false } }
        default: messages = []
        }
        for message in messages {
            guard !relay.finished else { return }
            guard await relay.channel.deliver(relay.id, message) else {
                if relays[relay.id] === relay {
                    relays.removeValue(forKey: relay.id)
                    retire(relay, deleteSession: true)
                }
                return
            }
        }
    }

    private func terminate(_ relay: Relay, code: DeviceMcpFailCode, text: String) async {
        guard !relay.finished else { return }
        if relays[relay.id] === relay { relays.removeValue(forKey: relay.id) }
        retire(relay, deleteSession: code == .closed)
        await relay.channel.fail(relay.id, code, text)
    }

    private func finish(_ relay: Relay?, channel: DeviceMcpChannel, relayID: String, code: DeviceMcpFailCode, text: String) async {
        if let relay {
            await terminate(relay, code: code, text: text)
        } else {
            await channel.fail(relayID, code, text)
        }
    }

    private func retire(_ relay: Relay, deleteSession: Bool) {
        guard !relay.finished else { return }
        relay.finished = true
        for task in relay.tasks.values { task.cancel() }
        relay.tasks.removeAll()
        relay.held.removeAll()
        guard deleteSession, let sessionID = relay.sessionID else { return }
        let http = http
        let endpoint = relay.endpoint
        let token = relay.token
        Task { await http.delete(endpoint, token: token, sessionID: sessionID) }
    }
}
