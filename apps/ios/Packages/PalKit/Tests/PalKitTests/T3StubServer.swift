import Foundation
import Network
import Synchronization

struct StubRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    var rpcMethod: String? { json?["method"] as? String }
}

indirect enum StubReply: Sendable {
    case json(Int, String, headers: [String: String] = [:])
    case events([(delay: Duration, text: String)], headers: [String: String] = [:])
    case status(Int, headers: [String: String] = [:])
    case delayed(Duration, StubReply)
    case drop
}

final class T3StubServer: @unchecked Sendable {
    typealias Handler = @Sendable (StubRequest) async -> StubReply

    private let listener: NWListener
    private let queue = DispatchQueue(label: "t3-stub-server")
    private let handler: Handler
    private let log = Mutex<[StubRequest]>([])

    private init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    static func start(_ handler: @escaping Handler) async throws -> T3StubServer {
        let server = try T3StubServer(handler: handler)
        server.listener.newConnectionHandler = { [unowned server] connection in server.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            server.listener.stateUpdateHandler = { state in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    switch state {
                    case .ready, .failed: done = true; return true
                    default: return false
                    }
                }
                guard first else { return }
                if case .failed(let error) = state { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var origin: String { "http://127.0.0.1:\(port)" }
    var requests: [StubRequest] { log.withLock { $0 } }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.log.withLock { $0.append(request) }
                Task { await self.respond(to: request, over: connection) }
                return
            }
            if error != nil || isComplete { return connection.cancel() }
            self.read(connection, buffer: buffer)
        }
    }

    private static func parse(_ buffer: Data) -> StubRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[line.startIndex..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = buffer[separator.upperBound...]
        guard body.count >= length else { return nil }
        return StubRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(to request: StubRequest, over connection: NWConnection) async {
        var reply = await handler(request)
        while case .delayed(let delay, let inner) = reply {
            try? await Task.sleep(for: delay)
            reply = inner
        }
        switch reply {
        case .json(let status, let body, let headers):
            let payload = Data(body.utf8)
            var all = headers
            all["Content-Type"] = all["Content-Type"] ?? "application/json"
            all["Content-Length"] = "\(payload.count)"
            await write(connection, Self.head(status, all) + payload)
        case .status(let status, let headers):
            var all = headers
            all["Content-Length"] = "0"
            await write(connection, Self.head(status, all))
        case .events(let chunks, let headers):
            var all = headers
            all["Content-Type"] = "text/event-stream"
            await write(connection, Self.head(200, all))
            for chunk in chunks {
                try? await Task.sleep(for: chunk.delay)
                await write(connection, Data(chunk.text.utf8))
            }
        case .drop:
            connection.cancel()
            return
        case .delayed:
            break
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func head(_ status: Int, _ headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nConnection: close\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private func write(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
