import Foundation
import HermesDiagnostics

public enum RFBTransportError: Error, Equatable, Sendable {
    case closed(code: Int?)
    case textFrame
}

public protocol RFBTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public enum RFBSessionEnd: Equatable, Sendable {
    case closed
    case controlTaken
    case desktopGone
    case ticketRejected
    case failed(RFBFailure)
    case lost

    init(transportCode code: Int?) {
        switch code {
        case 1000?, 1001?: self = .closed
        case 4000?: self = .controlTaken
        case 4001?: self = .desktopGone
        case 4401?, 4403?: self = .ticketRejected
        default: self = .lost
        }
    }
}

public enum RFBSessionEvent: Equatable, Sendable {
    case ready(RFBSize, name: String)
    case resized(RFBSize)
    case bell
    case clipboard(String)
    case ended(RFBSessionEnd)
}

public actor RFBSession {
    public nonisolated let events: AsyncStream<RFBSessionEvent>
    public nonisolated let frames: AsyncStream<RFBFramebuffer>

    private let transport: any RFBTransport
    private let diagnostics: Diagnostics
    private let eventContinuation: AsyncStream<RFBSessionEvent>.Continuation
    private let frameContinuation: AsyncStream<RFBFramebuffer>.Continuation
    private var client = RFBClient()
    private var isReady = false
    private var hasEnded = false

    public init(transport: any RFBTransport, diagnostics: Diagnostics = .silent) {
        self.transport = transport
        self.diagnostics = diagnostics
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (frames, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var size: RFBSize { client.framebuffer.size }

    public func run() async {
        let end = await pump()
        finish(end)
        await transport.close()
    }

    public func close() async {
        finish(.closed)
        await transport.close()
    }

    public func pointer(buttons: UInt8, x: Int, y: Int) async {
        guard isReady else { return }
        await send(RFBClientMessages.pointer(buttons: buttons, x: x, y: y, within: client.framebuffer.size))
    }

    public func key(_ keysym: UInt32, down: Bool) async {
        guard isReady else { return }
        await send(RFBClientMessages.key(keysym, down: down))
    }

    public func tap(key keysym: UInt32) async {
        await key(keysym, down: true)
        await key(keysym, down: false)
    }

    public func type(_ text: String) async {
        for scalar in text.unicodeScalars { await tap(key: RFBKeysym.forScalar(scalar)) }
    }

    @discardableResult
    public func clipboard(_ text: String) async -> Bool {
        guard isReady, let message = RFBClientMessages.clientCutText(text) else { return false }
        await send(message)
        return true
    }

    private func pump() async -> RFBSessionEnd {
        do {
            while !Task.isCancelled {
                let step = try client.receive(try await transport.receive())
                for reply in step.replies { try await transport.send(reply) }
                handle(step.events)
            }
            return .closed
        } catch let failure as RFBFailure {
            diagnostics.warning("rfb", "protocol failure: \(failure)")
            return .failed(failure)
        } catch RFBTransportError.closed(let code) {
            return RFBSessionEnd(transportCode: code)
        } catch {
            diagnostics.info("rfb", "stream ended: \(Diagnostics.describe(error))")
            return .lost
        }
    }

    private func handle(_ events: [RFBEvent]) {
        for event in events {
            switch event {
            case .ready(let size, let name):
                isReady = true
                eventContinuation.yield(.ready(size, name: name))
                frameContinuation.yield(client.framebuffer)
            case .updated:
                frameContinuation.yield(client.framebuffer)
            case .resized(let size):
                eventContinuation.yield(.resized(size))
                frameContinuation.yield(client.framebuffer)
            case .bell:
                eventContinuation.yield(.bell)
            case .serverCutText(let text):
                eventContinuation.yield(.clipboard(text))
            }
        }
    }

    private func send(_ data: Data) async {
        do {
            try await transport.send(data)
        } catch {
            diagnostics.info("rfb", "send failed: \(Diagnostics.describe(error))")
        }
    }

    private func finish(_ end: RFBSessionEnd) {
        guard !hasEnded else { return }
        hasEnded = true
        isReady = false
        eventContinuation.yield(.ended(end))
        eventContinuation.finish()
        frameContinuation.finish()
    }
}
