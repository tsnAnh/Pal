import Foundation
import HermesChat
import HermesProtocol
import HermesTransport
import Network
import Synchronization

final class FakeGateway: @unchecked Sendable {
    enum Reply: Sendable {
        case result(JSONValue)
        case failure(RPCError)
        case delayed(Duration, JSONValue)
        case silence
    }

    typealias Handler = @Sendable (_ method: String, _ params: JSONValue?, _ connection: Int) -> Reply

    private struct State {
        var connections: [Int: NWConnection] = [:]
        var live: Set<Int> = []
        var nextIndex = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-gateway")
    private let state = Mutex(State())
    private let handler: Handler

    private init(handler: @escaping Handler) throws {
        self.handler = handler
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { subprotocols, _ in
            let chosen = subprotocols.contains(GatewayConnection.subprotocol) ? GatewayConnection.subprotocol : nil
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: chosen)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    static func start(_ handler: @escaping Handler) async throws -> FakeGateway {
        let gateway = try FakeGateway(handler: handler)
        gateway.listener.newConnectionHandler = { [unowned gateway] connection in gateway.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            gateway.listener.stateUpdateHandler = { newState in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    switch newState {
                    case .ready, .failed: done = true; return true
                    default: return false
                    }
                }
                guard first else { return }
                if case .failed(let error) = newState { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            gateway.listener.start(queue: gateway.queue)
        }
        return gateway
    }

    var url: URL {
        URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/api/ws")!
    }

    var connectionCount: Int { state.withLock { $0.nextIndex } }
    var liveConnectionCount: Int { state.withLock { $0.live.count } }

    func push(_ params: JSONValue, to connection: Int? = nil) {
        let targets = state.withLock { state in
            state.connections.filter { state.live.contains($0.key) && (connection == nil || $0.key == connection) }.map(\.value)
        }
        for target in targets { send(["jsonrpc": "2.0", "method": "event", "params": params], over: target) }
    }

    func dropAll() {
        let targets = state.withLock { state in state.connections.filter { state.live.contains($0.key) }.map(\.value) }
        for target in targets { target.forceCancel() }
    }

    func stop() {
        listener.cancel()
        let all = state.withLock { $0.connections.values.map { $0 } }
        for connection in all { connection.forceCancel() }
    }

    private func accept(_ connection: NWConnection) {
        let index = state.withLock { state -> Int in
            let index = state.nextIndex
            state.nextIndex += 1
            state.connections[index] = connection
            return index
        }
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                state.withLock { _ = $0.live.insert(index) }
                send(["jsonrpc": "2.0", "method": "event", "params": ["type": "gateway.ready", "payload": [:]]], over: connection)
                receive(connection, index)
            case .failed, .cancelled:
                state.withLock { _ = $0.live.remove(index) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, _ index: Int) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                state.withLock { _ = $0.live.remove(index) }
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                state.withLock { _ = $0.live.remove(index) }
                return
            }
            if let data, metadata?.opcode == .text { handle(data, over: connection, index: index) }
            receive(connection, index)
        }
    }

    private func handle(_ data: Data, over connection: NWConnection, index: Int) {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
              let method = frame["method"]?.stringValue, let id = frame["id"]?.intValue
        else { return }
        switch handler(method, frame["params"], index) {
        case .result(let result):
            send(["jsonrpc": "2.0", "id": .int(id), "result": result], over: connection)
        case .failure(let error):
            send(["jsonrpc": "2.0", "id": .int(id), "error": failureObject(error)], over: connection)
        case .delayed(let delay, let result):
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay.components.seconds * 1000 + delay.components.attoseconds / 1_000_000_000_000_000))) { [self] in
                send(["jsonrpc": "2.0", "id": .int(id), "result": result], over: connection)
            }
        case .silence:
            break
        }
    }

    private func failureObject(_ error: RPCError) -> JSONValue {
        var object: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
        if let data = error.data { object["data"] = data }
        return .object(object)
    }

    private func send(_ value: JSONValue, over connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

final class BotScript: Sendable {
    typealias Override = @Sendable (_ callNumber: Int) -> FakeGateway.Reply?

    static let sessionID = "s1"
    static let epoch = "e1"

    private let counts = Mutex<[String: Int]>([:])
    private let overrides = Mutex<[String: Override]>([:])
    let messages = Mutex<[(role: String, text: String)]>([])
    let lastSequence = Mutex(1)
    let submitted = Mutex<[JSONValue]>([])
    let received = Mutex<[String: [JSONValue]]>([:])

    func calls(_ method: String) -> [JSONValue] { received.withLock { $0[method] ?? [] } }

    func count(_ method: String) -> Int { counts.withLock { $0[method] ?? 0 } }

    func override(_ method: String, _ body: @escaping Override) {
        overrides.withLock { $0[method] = body }
    }

    var snapshot: JSONValue {
        let rows: [JSONValue] = messages.withLock { stored in
            stored.enumerated().map { index, message in
                ["role": .string(message.role), "text": .string(message.text), "row_id": .int(index + 1)]
            }
        }
        return [
            "session_id": .string(Self.sessionID),
            "messages": .array(rows),
            "running": false,
            "replay_epoch": .string(Self.epoch),
            "last_sequence": .int(lastSequence.withLock { $0 }),
            "execution_generation": 1,
            "pending": [],
            "prompts": [],
        ]
    }

    var snapshotWithPrompt: JSONValue {
        var object = snapshot.objectValue ?? [:]
        object["running"] = true
        object["prompts"] = [[
            "kind": "clarify", "prompt_id": "p1", "execution_generation": 1, "question": "Which flavor?", "choices": ["a", "b"],
        ]]
        return .object(object)
    }

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        let number = counts.withLock { counts -> Int in
            counts[method, default: 0] += 1
            return counts[method] ?? 0
        }
        if let params { received.withLock { $0[method, default: []].append(params) } }
        if let reply = overrides.withLock({ $0[method] })?(number) { return reply }
        switch method {
        case "session.list":
            return .result(["sessions": [["session_id": .string(Self.sessionID), "title": "Bot Chat", "resolved_id": .string(Self.sessionID)]]])
        case "session.resume":
            return .result(snapshot)
        case "session.events.since":
            return .result([
                "events": [], "latest_seq": .int(lastSequence.withLock { $0 }), "replay_epoch": .string(Self.epoch),
                "snapshot_required": false,
            ])
        case "prompt.submit":
            if let params { submitted.withLock { $0.append(params) } }
            return .result(["admission_id": .string("a-\(number)"), "status": "queued"])
        case "clarify.respond", "approval.respond":
            return .result(["status": "resolved", "prompt_id": params?["prompt_id"] ?? ""])
        case "image.attach_bytes":
            let name = params?["filename"]?.stringValue ?? "image.png"
            return .result([
                "attached": true, "path": .string("/cache/images/upload_\(number)_\(name)"),
                "name": .string("upload_\(number)_\(name)"),
                "mime": .string(name.hasSuffix(".jpg") ? "image/jpeg" : "image/png"),
                "text": .string("[User attached image: upload_\(number)_\(name)]"),
            ])
        case "file.attach":
            let name = params?["name"]?.stringValue ?? "file"
            return .result([
                "attached": true, "name": .string(name), "path": .string("/attachments/\(name)"),
                "ref_text": .string("@file:attachments/\(name)"),
            ])
        case "session.interrupt":
            return .result(["status": "interrupted"])
        case "session.steer":
            return .result(["status": "queued", "text": params?["text"] ?? ""])
        default:
            return .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
        }
    }

    func event(_ type: String, seq: Int, payload: JSONValue) -> JSONValue {
        [
            "type": .string(type),
            "session_id": .string(Self.sessionID),
            "seq": .int(seq),
            "replay_epoch": .string(Self.epoch),
            "payload": payload,
        ]
    }
}

final class ScriptedConnector: ChatConnector {
    private let url: URL
    private let attemptCount = Mutex(0)
    private let failure: Mutex<@Sendable (Int) -> (any Error)?>
    private let delay: Mutex<Duration>
    private let dialedConnections = Mutex<[GatewayConnection]>([])

    init(url: URL, delay: Duration = .zero, failure: @escaping @Sendable (Int) -> (any Error)? = { _ in nil }) {
        self.url = url
        self.delay = Mutex(delay)
        self.failure = Mutex(failure)
    }

    var attempts: Int { attemptCount.withLock { $0 } }
    var dialed: [GatewayConnection] { dialedConnections.withLock { $0 } }

    func failConnects(_ body: @escaping @Sendable (Int) -> (any Error)?) {
        failure.withLock { $0 = body }
    }

    func connect() async throws -> GatewayConnection {
        let index = attemptCount.withLock { count -> Int in
            count += 1
            return count - 1
        }
        let wait = delay.withLock { $0 }
        if wait > .zero { try await Task.sleep(for: wait) }
        if let error = failure.withLock({ $0 })(index) { throw error }
        let connection = try await GatewayConnection.dial(
            url: url,
            ticket: "test-ticket",
            options: GatewayDialOptions(readyTimeout: .seconds(5), requestTimeout: .seconds(5))
        )
        dialedConnections.withLock { $0.append(connection) }
        return connection
    }
}
