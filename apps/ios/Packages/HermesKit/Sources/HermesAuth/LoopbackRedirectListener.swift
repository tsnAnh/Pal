import Foundation
import HermesDiagnostics
import Network

public final class LoopbackRedirectListener: @unchecked Sendable {
    public static let callbackPath = "/callback"
    private static let maxRequestBytes = 16 * 1024

    public private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "dev.tsnanh.hermes.loopback-redirect")
    private let listener: NWListener
    private let diagnostics: Diagnostics
    private var outcome: Result<[String: String], SignInError>?
    private var waiter: CheckedContinuation<[String: String], any Error>?
    private var finished = false

    public var redirectURI: String { "http://127.0.0.1:\(port)\(Self.callbackPath)" }

    private init(listener: NWListener, diagnostics: Diagnostics) {
        self.listener = listener
        self.diagnostics = diagnostics
    }

    public static func start(timeout: Duration = .seconds(300), diagnostics: Diagnostics = .silent) async throws -> LoopbackRedirectListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw SignInError.listenerFailed
        }
        let instance = LoopbackRedirectListener(listener: nwListener, diagnostics: diagnostics)
        try await instance.begin(timeout: timeout)
        diagnostics.info("loopback", "listening on 127.0.0.1:\(instance.port)")
        return instance
    }

    private func begin(timeout: Duration) async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.handle(connection)
        }
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Flag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if resumed.claim() {
                        if let port = self?.listener.port?.rawValue {
                            continuation.resume(returning: port)
                        } else {
                            continuation.resume(throwing: SignInError.listenerFailed)
                        }
                    }
                case .failed, .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: SignInError.listenerFailed)
                    } else {
                        self?.finishOnQueue(.failure(.listenerFailed))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            port = boundPort
            let nanoseconds = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { [weak self] in
                self?.finishOnQueue(.failure(.listenerTimedOut))
            }
        }
    }

    public func awaitCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let outcome = self.outcome {
                        self.waiter = nil
                        continuation.resume(with: outcome.mapError { $0 as any Error })
                    } else {
                        self.waiter = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(.cancelled))
        }
    }

    public func cancel() {
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<[String: String], SignInError>) {
        queue.async { self.finishOnQueue(result) }
    }

    private func finishOnQueue(_ result: Result<[String: String], SignInError>) {
        guard !finished else { return }
        finished = true
        outcome = result
        listener.newConnectionHandler = { $0.cancel() }
        listener.cancel()
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result.mapError { $0 as any Error })
        }
        diagnostics.info("loopback", "listener closed")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: connection, head: buffer[..<end.lowerBound])
            } else if error != nil || isComplete || buffer.count > Self.maxRequestBytes {
                self.reply(on: connection, status: "400 Bad Request", body: Self.page("Invalid request."), then: nil)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to connection: NWConnection, head: Data) {
        guard !finished else {
            reply(on: connection, status: "410 Gone", body: Self.page("This sign-in link was already used."), then: nil)
            return
        }
        guard let request = Self.parse(head: head, expectedHost: "127.0.0.1:\(port)") else {
            reply(on: connection, status: "404 Not Found", body: Self.page("Not found."), then: nil)
            return
        }
        diagnostics.info("loopback", "received redirect callback")
        reply(
            on: connection,
            status: "200 OK",
            body: Self.page("Signed in. You can return to Pal."),
            then: { [weak self] in self?.finishOnQueue(.success(request)) }
        )
    }

    private func reply(on connection: NWConnection, status: String, body: Data, then completion: (@Sendable () -> Void)?) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        completion?()
    }

    static func parse(head: Data, expectedHost: String) -> [String: String]? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[0] == "GET" else { return nil }
        guard let components = URLComponents(string: String(requestLine[1])), components.path == callbackPath else { return nil }
        let host = lines.first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() }
        guard host == expectedHost else { return nil }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, parameters[item.name] == nil { parameters[item.name] = value }
        }
        return parameters
    }

    private static func page(_ message: String) -> Data {
        Data("<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Pal</title><body style=\"font:-apple-system-body;font-family:-apple-system,sans-serif;padding:2rem;text-align:center\"><p>\(message)</p></body>".utf8)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}
