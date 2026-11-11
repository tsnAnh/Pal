import Foundation
import PalRFB
import Synchronization
import Testing

private final class ScriptedTransport: RFBTransport {
    enum Inbound: Sendable {
        case data(Data)
        case fail(any Error)
    }

    private let inbox: AsyncStream<Inbound>
    private let feed: AsyncStream<Inbound>.Continuation
    private let sentLog = Mutex<[Data]>([])

    init() {
        (inbox, feed) = AsyncStream.makeStream()
    }

    var sent: [Data] { sentLog.withLock { $0 } }

    func deliver(_ data: Data) { feed.yield(.data(data)) }
    func fail(_ error: any Error) { feed.yield(.fail(error)) }

    func send(_ data: Data) async throws { sentLog.withLock { $0.append(data) } }

    func receive() async throws -> Data {
        for await item in inbox {
            switch item {
            case .data(let data): return data
            case .fail(let error): throw error
            }
        }
        throw RFBTransportError.closed(code: 1000)
    }

    func close() async { feed.finish() }
}

private let handshake = Data(Array("RFB 003.008\n".utf8) + [1, 1] + [0, 0, 0, 0])

private func serverInit(width: Int, height: Int) -> Data {
    func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    return Data(be16(width) + be16(height) + RFBPixelFormat.bgrx.encoded + [0, 0, 0, 0])
}

private func ended(_ session: RFBSession) async -> RFBSessionEnd? {
    for await event in session.events {
        if case .ended(let end) = event { return end }
    }
    return nil
}

@Suite("RFB session")
struct RFBSessionTests {
    @Test("a stream closed by the bridge with the control-taken code ends as control taken")
    func controlTaken() async {
        let transport = ScriptedTransport()
        let session = RFBSession(transport: transport)
        transport.fail(RFBTransportError.closed(code: 4000))
        await session.run()
        #expect(await ended(session) == .controlTaken)
    }

    @Test("desktop gone, rejected ticket, clean close and a dropped link each end distinctly")
    func closeCodes() async {
        let expectations: [(Int?, RFBSessionEnd)] = [(4001, .desktopGone), (4401, .ticketRejected), (1000, .closed), (nil, .lost), (1006, .lost)]
        for (code, expected) in expectations {
            let transport = ScriptedTransport()
            let session = RFBSession(transport: transport)
            transport.fail(RFBTransportError.closed(code: code))
            await session.run()
            #expect(await ended(session) == expected)
        }
    }

    @Test("a text frame from the bridge ends the session as a lost link")
    func textFrame() async {
        let transport = ScriptedTransport()
        let session = RFBSession(transport: transport)
        transport.fail(RFBTransportError.textFrame)
        await session.run()
        #expect(await ended(session) == .lost)
    }

    @Test("a protocol violation ends the session with the failure")
    func protocolFailure() async {
        let transport = ScriptedTransport()
        let session = RFBSession(transport: transport)
        transport.deliver(Data("HTTP/1.1 400 Bad\r\n".utf8))
        await session.run()
        #expect(await ended(session) == .failed(.unsupportedVersion))
    }

    @Test("input sent before the desktop is ready never reaches the wire")
    func inputBeforeReady() async {
        let transport = ScriptedTransport()
        let session = RFBSession(transport: transport)
        await session.pointer(buttons: 1, x: 5, y: 5)
        await session.key(0x61, down: true)
        #expect(await session.clipboard("hello") == false)
        #expect(transport.sent.isEmpty)
    }

    @Test("once the desktop is ready, pointer, keys and typed text reach the wire as RFB messages")
    func inputAfterReady() async throws {
        let transport = ScriptedTransport()
        let session = RFBSession(transport: transport)
        let running = Task { await session.run() }
        transport.deliver(handshake + serverInit(width: 100, height: 50))
        for await event in session.events {
            if case .ready = event { break }
        }
        await session.pointer(buttons: RFBButtons.left, x: 10, y: 20)
        await session.type("a")
        await session.close()
        await running.value
        let sent = transport.sent
        #expect(sent.contains(Data([5, 1, 0, 10, 0, 20])))
        #expect(sent.contains(Data([4, 1, 0, 0, 0, 0, 0, 0x61])))
        #expect(sent.contains(Data([4, 0, 0, 0, 0, 0, 0, 0x61])))
    }
}
