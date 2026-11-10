import Foundation
import HermesDiagnostics
import HermesProtocol
import Synchronization

public enum GatewayTransportError: Error, Sendable, Equatable {
    case handshakeRejected(status: Int)
    case subprotocolNotNegotiated
    case unexpectedFirstFrame
    case timedOut
    case closed(GatewayCloseReason)
    case encoding
    case rpc(RPCError)
}

extension GatewayTransportError: DiagnosticSummarizing {
    public var diagnosticSummary: String {
        switch self {
        case .handshakeRejected(let status): "GatewayTransportError.handshakeRejected status=\(status)"
        case .subprotocolNotNegotiated: "GatewayTransportError.subprotocolNotNegotiated"
        case .unexpectedFirstFrame: "GatewayTransportError.unexpectedFirstFrame"
        case .timedOut: "GatewayTransportError.timedOut"
        case .closed(let reason): "GatewayTransportError.closed reason=\(reason)"
        case .encoding: "GatewayTransportError.encoding"
        case .rpc(let error): error.diagnosticSummary
        }
    }
}

public enum GatewayCloseReason: Sendable, Equatable {
    case normal
    case unauthorized
    case forbidden
    case tryAgainLater
    case other(Int)
    case lost

    init(code: Int?) {
        switch code {
        case nil: self = .lost
        case 1000?, 1001?: self = .normal
        case 4401?: self = .unauthorized
        case 4403?: self = .forbidden
        case 1013?: self = .tryAgainLater
        case let code?: self = .other(code)
        }
    }
}

public enum FrameDirection: String, Sendable {
    case outbound
    case inbound
}

public typealias FrameTap = @Sendable (FrameDirection, String) -> Void

public struct GatewayDialOptions: Sendable {
    public var readyTimeout: Duration
    public var requestTimeout: Duration
    public var frameTap: FrameTap?

    public init(
        readyTimeout: Duration = .seconds(15),
        requestTimeout: Duration = .seconds(30),
        frameTap: FrameTap? = nil
    ) {
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
        self.frameTap = frameTap
    }
}

final class SocketObserver: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    struct State {
        var negotiatedProtocol: String?
        var closeCode: Int?
        var opened = false
    }

    let state = Mutex(State())

    func negotiatedProtocol(for task: URLSessionWebSocketTask) async -> String? {
        if let header = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") {
            return header.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let snapshot = state.withLock { $0 }
            if snapshot.opened { return snapshot.negotiatedProtocol }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return state.withLock { $0.negotiatedProtocol }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        state.withLock {
            $0.negotiatedProtocol = `protocol`
            $0.opened = true
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        state.withLock { $0.closeCode = closeCode.rawValue }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

public actor GatewayConnection {
    public static let subprotocol = "hermes-gateway-v1"
    public static let ticketSubprotocolPrefix = "hermes-gateway-ticket."
    static let maximumMessageBytes = 64 * 1024 * 1024

    public nonisolated let events: AsyncStream<GatewayEvent>
    public nonisolated let serverRequests: AsyncStream<RPCRequest>
    private let eventContinuation: AsyncStream<GatewayEvent>.Continuation
    private let requestContinuation: AsyncStream<RPCRequest>.Continuation
    private let frameTap: FrameTap?
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let observer: SocketObserver
    private let diagnostics: Diagnostics
    private let requestTimeout: Duration
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readyWaiter: CheckedContinuation<GatewayEvent, any Error>?
    private var readyEvent: GatewayEvent?
    private var receiveTask: Task<Void, Never>?
    private var closeReason: GatewayCloseReason?
    private nonisolated let negotiated = Mutex<JSONValue?>(nil)

    private init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        observer: SocketObserver,
        diagnostics: Diagnostics,
        requestTimeout: Duration,
        frameTap: FrameTap?
    ) {
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (serverRequests, requestContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.frameTap = frameTap
        self.session = session
        self.task = task
        self.observer = observer
        self.diagnostics = diagnostics
        self.requestTimeout = requestTimeout
    }

    public static func dial(
        url: URL,
        ticket: String,
        options: GatewayDialOptions = GatewayDialOptions(),
        diagnostics: Diagnostics = .silent
    ) async throws -> GatewayConnection {
        let observer = SocketObserver()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        let task = session.webSocketTask(with: url, protocols: [subprotocol, ticketSubprotocolPrefix + ticket])
        task.maximumMessageSize = maximumMessageBytes
        let connection = GatewayConnection(
            session: session,
            task: task,
            observer: observer,
            diagnostics: diagnostics,
            requestTimeout: options.requestTimeout,
            frameTap: options.frameTap
        )
        diagnostics.info("ws", "dialing \(Diagnostics.describe(url))")
        task.resume()
        await connection.startReceiving()
        do {
            let ready = try await connection.awaitReady(timeout: options.readyTimeout)
            guard await observer.negotiatedProtocol(for: task) == subprotocol else {
                throw GatewayTransportError.subprotocolNotNegotiated
            }
            diagnostics.info("ws", "connected; \(ready.type) received, subprotocol \(subprotocol)")
            return connection
        } catch {
            diagnostics.warning("ws", "dial failed: \(Diagnostics.describe(error))")
            await connection.close()
            throw error
        }
    }

    public func call(_ method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue {
        if let closeReason { throw GatewayTransportError.closed(closeReason) }
        let id = nextID
        nextID += 1
        let frame: String
        do {
            let data = try RPCCodec.encode(RPCRequest(id: .int(id), method: method, params: params))
            frame = String(decoding: data, as: UTF8.self)
        } catch {
            throw GatewayTransportError.encoding
        }
        let limit = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { await self.transmit(frame, id: id) }
                Task {
                    try? await Task.sleep(for: limit)
                    self.expire(id)
                }
            }
        } onCancel: {
            Task { await self.fail(id, with: CancellationError()) }
        }
    }

    public var isClosed: Bool { closeReason != nil }

    public nonisolated var negotiatedRuntime: JSONValue? { negotiated.withLock { $0 } }

    public nonisolated func recordNegotiatedRuntime(_ description: JSONValue) {
        negotiated.withLock { $0 = description }
    }

    public func ping() async throws {
        let result = try await call("gateway.ping", timeout: .seconds(10))
        guard result["ok"]?.boolValue == true else { throw GatewayTransportError.unexpectedFirstFrame }
    }

    public func respond(to id: RPCID, result: JSONValue) {
        sendResponse(RPCResponse(id: id, result: result))
    }

    public func reject(_ id: RPCID, code: Int, message: String) {
        sendResponse(RPCResponse(id: id, error: RPCError(code: code, message: message)))
    }

    public func close() {
        guard closeReason == nil else { return }
        task.cancel(with: .normalClosure, reason: nil)
        terminate(.normal)
    }

    public func abort() {
        guard closeReason == nil else { return }
        task.cancel()
        terminate(.lost)
    }

    private func sendResponse(_ response: RPCResponse) {
        guard closeReason == nil, let data = try? RPCCodec.encode(response) else { return }
        let frame = String(decoding: data, as: UTF8.self)
        frameTap?(.outbound, frame)
        Task { try? await task.send(.string(frame)) }
    }

    private func startReceiving() {
        receiveTask = Task { [task] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let raw): data = raw
                    @unknown default: continue
                    }
                    self.handle(data)
                } catch {
                    self.receiveFailed()
                    return
                }
            }
        }
    }

    private func handle(_ data: Data) {
        frameTap?(.inbound, String(decoding: data, as: UTF8.self))
        let message: RPCMessage
        do {
            message = try RPCCodec.decode(data)
        } catch {
            diagnostics.warning("ws", "dropped undecodable frame (\(data.count) bytes)")
            return
        }
        switch message {
        case .response(let response):
            guard case .int(let id)? = response.id, let continuation = pending.removeValue(forKey: id) else { return }
            if let error = response.error {
                continuation.resume(throwing: GatewayTransportError.rpc(error))
            } else {
                continuation.resume(returning: response.result ?? .null)
            }
        case .notification(let notification):
            guard let event = GatewayEvent(notification: notification) else { return }
            if event.type == "gateway.ready", readyEvent == nil {
                readyEvent = event
                readyWaiter?.resume(returning: event)
                readyWaiter = nil
            } else if readyEvent == nil {
                readyWaiter?.resume(throwing: GatewayTransportError.unexpectedFirstFrame)
                readyWaiter = nil
                readyEvent = event
            }
            eventContinuation.yield(event)
        case .request(let request):
            requestContinuation.yield(request)
        }
    }

    private func awaitReady(timeout: Duration) async throws -> GatewayEvent {
        if let readyEvent {
            guard readyEvent.type == "gateway.ready" else { throw GatewayTransportError.unexpectedFirstFrame }
            return readyEvent
        }
        return try await withCheckedThrowingContinuation { continuation in
            readyWaiter = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.expireReady()
            }
        }
    }

    private func expireReady() {
        guard let waiter = readyWaiter else { return }
        readyWaiter = nil
        waiter.resume(throwing: GatewayTransportError.timedOut)
    }

    private func transmit(_ frame: String, id: Int) async {
        frameTap?(.outbound, frame)
        do {
            try await task.send(.string(frame))
        } catch {
            fail(id, with: GatewayTransportError.closed(closeReason ?? .lost))
        }
    }

    private func expire(_ id: Int) {
        fail(id, with: GatewayTransportError.timedOut)
    }

    private func fail(_ id: Int, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveFailed() {
        if closeReason != nil { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let opened = observer.state.withLock { $0.opened }
        let code = observer.state.withLock { $0.closeCode } ?? (task.closeCode == .invalid ? nil : task.closeCode.rawValue)
        let reason = GatewayCloseReason(code: code)
        if !opened, let status, status != 101 {
            readyWaiter?.resume(throwing: GatewayTransportError.handshakeRejected(status: status))
            readyWaiter = nil
        }
        diagnostics.info("ws", "connection ended (\(reason))")
        terminate(reason)
    }

    private func terminate(_ reason: GatewayCloseReason) {
        closeReason = reason
        receiveTask?.cancel()
        readyWaiter?.resume(throwing: GatewayTransportError.closed(reason))
        readyWaiter = nil
        let outstanding = pending
        pending.removeAll()
        for continuation in outstanding.values {
            continuation.resume(throwing: GatewayTransportError.closed(reason))
        }
        eventContinuation.finish()
        requestContinuation.finish()
        session.finishTasksAndInvalidate()
    }
}
