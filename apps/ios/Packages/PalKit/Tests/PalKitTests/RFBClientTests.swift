import Foundation
import PalRFB
import Testing

private enum Server {
    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { be16(value >> 16 & 0xFFFF) + be16(value & 0xFFFF) }

    static func handshake(version: String = "RFB 003.008\n", security: [UInt8] = [1], result: [UInt8]? = [0, 0, 0, 0]) -> Data {
        var bytes = Array(version.utf8) + [UInt8(security.count)] + security
        if let result { bytes += result }
        return Data(bytes)
    }

    static func serverInit(width: Int, height: Int, name: String = "desktop") -> Data {
        var bytes = be16(width) + be16(height) + RFBPixelFormat.bgrx.encoded
        bytes += be32(name.utf8.count) + Array(name.utf8)
        return Data(bytes)
    }

    static func rect(x: Int, y: Int, width: Int, height: Int, encoding: Int32, payload: [UInt8]) -> [UInt8] {
        be16(x) + be16(y) + be16(width) + be16(height) + be32(Int(UInt32(bitPattern: encoding))) + payload
    }

    static func update(_ rects: [[UInt8]]) -> Data {
        Data([0, 0] + be16(rects.count) + rects.flatMap { $0 })
    }

    static func solid(_ blue: UInt8, _ green: UInt8, _ red: UInt8, count: Int) -> [UInt8] {
        (0..<count).flatMap { _ in [blue, green, red, 0] }
    }
}

private func readyClient(width: Int = 4, height: Int = 3) throws -> RFBClient {
    var client = RFBClient()
    _ = try client.receive(Server.handshake())
    _ = try client.receive(Server.serverInit(width: width, height: height))
    return client
}

@Suite("RFB client")
struct RFBClientTests {
    @Test("the handshake answers in the order the Hermes bridge expects: version, None, shared ClientInit")
    func handshakeReplies() throws {
        var client = RFBClient()
        let step = try client.receive(Server.handshake())
        #expect(step.replies == [Data("RFB 003.008\n".utf8), Data([1]), Data([1])])
        #expect(step.events.isEmpty)
    }

    @Test("the handshake survives being delivered one byte at a time")
    func byteAtATime() throws {
        var client = RFBClient()
        var replies: [Data] = []
        var events: [RFBEvent] = []
        for byte in Server.handshake() + Server.serverInit(width: 4, height: 3) {
            let step = try client.receive(Data([byte]))
            replies += step.replies
            events += step.events
        }
        #expect(events == [.ready(RFBSize(width: 4, height: 3), name: "desktop")])
        #expect(replies.first == Data("RFB 003.008\n".utf8))
        #expect(client.framebuffer.size == RFBSize(width: 4, height: 3))
    }

    @Test("server init asks for 32-bit BGRX, CopyRect and Raw, then a full non-incremental update")
    func serverInitReplies() throws {
        var client = RFBClient()
        _ = try client.receive(Server.handshake())
        let step = try client.receive(Server.serverInit(width: 4, height: 3))
        #expect(step.replies == [
            RFBClientMessages.setPixelFormat(),
            RFBClientMessages.setEncodings(),
            RFBClientMessages.updateRequest(incremental: false, x: 0, y: 0, width: 4, height: 3),
        ])
    }

    @Test("an RFB 3.7 server is accepted and sends no security result")
    func version37() throws {
        var client = RFBClient()
        let step = try client.receive(Server.handshake(version: "RFB 003.007\n", result: nil) + Server.serverInit(width: 2, height: 2))
        #expect(step.replies.first == Data("RFB 003.007\n".utf8))
        #expect(step.events == [.ready(RFBSize(width: 2, height: 2), name: "desktop")])
    }

    @Test("an unknown or too-old protocol version fails")
    func unsupportedVersion() {
        for banner in ["RFB 003.003\n", "RFB 004.000\n", "HTTP/1.1 400 \n", "RFB 003.008X"] {
            var client = RFBClient()
            #expect(throws: RFBFailure.unsupportedVersion) { try client.receive(Data(banner.utf8)) }
        }
    }

    @Test("a server that offers only password security fails instead of sending a bad choice")
    func passwordOnly() {
        var client = RFBClient()
        #expect(throws: RFBFailure.unsupportedSecurity) { try client.receive(Server.handshake(security: [2], result: nil)) }
    }

    @Test("a server that refuses the connection with a reason fails with the refusal")
    func refusedConnection() {
        var client = RFBClient()
        let reason = Array("too many connections".utf8)
        let bytes = Array("RFB 003.008\n".utf8) + [0] + Server.be32(reason.count) + reason
        #expect(throws: RFBFailure.securityRefused) { try client.receive(Data(bytes)) }
    }

    @Test("a failed security result fails")
    func securityResultFailed() {
        var client = RFBClient()
        let reason = Array("no".utf8)
        let bytes = Server.handshake(result: Server.be32(1) + Server.be32(reason.count) + reason)
        #expect(throws: RFBFailure.securityRefused) { try client.receive(bytes) }
    }

    @Test("a zero-sized, oversized or runaway-name server init fails")
    func invalidServerInit() throws {
        let cases: [Data] = [
            Server.serverInit(width: 0, height: 10),
            Server.serverInit(width: 10, height: 0),
            Server.serverInit(width: 16385, height: 10),
            Data(Server.be16(10) + Server.be16(10) + RFBPixelFormat.bgrx.encoded + Server.be32(1_000_000)),
        ]
        for bytes in cases {
            var client = RFBClient()
            _ = try client.receive(Server.handshake())
            #expect(throws: RFBFailure.invalidServerInit) { try client.receive(bytes) }
        }
    }

    @Test("a raw rectangle split across chunks paints nothing until it is whole")
    func rawSplit() throws {
        var client = try readyClient()
        let pixels = Server.solid(10, 20, 30, count: 4)
        let message = Server.update([Server.rect(x: 0, y: 0, width: 2, height: 2, encoding: 0, payload: pixels)])
        let head = message.prefix(message.count - 3)
        let tail = message.suffix(3)
        let first = try client.receive(Data(head))
        #expect(first.events.isEmpty)
        #expect(client.framebuffer.pixel(x: 0, y: 0) == [0, 0, 0, 0])
        let second = try client.receive(Data(tail))
        #expect(second.events == [.updated([RFBRect(x: 0, y: 0, width: 2, height: 2)])])
        #expect(client.framebuffer.pixel(x: 1, y: 1) == [10, 20, 30, 0])
        #expect(client.framebuffer.pixel(x: 2, y: 0) == [0, 0, 0, 0])
        #expect(second.replies == [RFBClientMessages.updateRequest(incremental: true, x: 0, y: 0, width: 4, height: 3)])
    }

    @Test("two messages in one chunk are both applied in order")
    func coalescedMessages() throws {
        var client = try readyClient()
        let paint = Server.update([Server.rect(x: 0, y: 0, width: 1, height: 1, encoding: 0, payload: [1, 2, 3, 0])])
        let bell = Data([2])
        let step = try client.receive(paint + bell)
        #expect(step.events == [.updated([RFBRect(x: 0, y: 0, width: 1, height: 1)]), .bell])
    }

    @Test("CopyRect with overlapping source and destination copies the original pixels")
    func copyRectOverlap() throws {
        var client = try readyClient(width: 4, height: 1)
        let row: [UInt8] = [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0]
        _ = try client.receive(Server.update([Server.rect(x: 0, y: 0, width: 4, height: 1, encoding: 0, payload: row)]))
        let step = try client.receive(Server.update([
            Server.rect(x: 1, y: 0, width: 3, height: 1, encoding: 1, payload: Server.be16(0) + Server.be16(0)),
        ]))
        #expect(step.events == [.updated([RFBRect(x: 1, y: 0, width: 3, height: 1)])])
        #expect((0..<4).map { client.framebuffer.pixel(x: $0, y: 0)[0] } == [1, 1, 2, 3])
    }

    @Test("a rectangle reaching outside the framebuffer fails and paints nothing")
    func rectangleOutOfBounds() throws {
        var client = try readyClient()
        let bad = Server.update([Server.rect(x: 3, y: 0, width: 2, height: 1, encoding: 0, payload: Server.solid(9, 9, 9, count: 2))])
        #expect(throws: RFBFailure.rectangleOutOfBounds) { try client.receive(bad) }
        #expect(client.framebuffer.pixel(x: 3, y: 0) == [0, 0, 0, 0])
    }

    @Test("a CopyRect whose source leaves the framebuffer fails")
    func copyRectSourceOutOfBounds() throws {
        var client = try readyClient()
        let bad = Server.update([Server.rect(x: 0, y: 0, width: 2, height: 2, encoding: 1, payload: Server.be16(3) + Server.be16(2))])
        #expect(throws: RFBFailure.rectangleOutOfBounds) { try client.receive(bad) }
    }

    @Test("an encoding the client never asked for fails")
    func unsupportedEncoding() throws {
        var client = try readyClient()
        let hextile = Server.update([Server.rect(x: 0, y: 0, width: 1, height: 1, encoding: 5, payload: [0])])
        #expect(throws: RFBFailure.unsupportedEncoding(5)) { try client.receive(hextile) }
    }

    @Test("an unknown server message type fails")
    func unsupportedMessage() throws {
        var client = try readyClient()
        #expect(throws: RFBFailure.unsupportedMessage(99)) { try client.receive(Data([99])) }
    }

    @Test("after a failure the client refuses more input")
    func failureIsSticky() throws {
        var client = try readyClient()
        _ = try? client.receive(Data([99]))
        #expect(throws: RFBFailure.unsupportedMessage(99)) { try client.receive(Server.update([])) }
    }

    @Test("a DesktopSize rectangle resizes the framebuffer and asks for a full repaint")
    func desktopResize() throws {
        var client = try readyClient()
        let resize = Server.update([Server.rect(x: 0, y: 0, width: 6, height: 5, encoding: -223, payload: [])])
        let step = try client.receive(resize)
        #expect(step.events == [.resized(RFBSize(width: 6, height: 5))])
        #expect(client.framebuffer.size == RFBSize(width: 6, height: 5))
        #expect(step.replies == [RFBClientMessages.updateRequest(incremental: false, x: 0, y: 0, width: 6, height: 5)])
    }

    @Test("a DesktopSize rectangle to zero or beyond the cap fails")
    func desktopResizeInvalid() throws {
        for (width, height) in [(0, 5), (5, 0), (20000, 5)] {
            var client = try readyClient()
            let resize = Server.update([Server.rect(x: 0, y: 0, width: width, height: height, encoding: -223, payload: [])])
            #expect(throws: RFBFailure.invalidServerInit) { try client.receive(resize) }
        }
    }

    @Test("clipboard text from the server is decoded as Latin-1 and delivered")
    func serverCutText() throws {
        var client = try readyClient()
        let text: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        let step = try client.receive(Data([3, 0, 0, 0] + Server.be32(text.count) + text))
        #expect(step.events == [.serverCutText("café")])
    }

    @Test("oversized or extended-format clipboard messages fail")
    func serverCutTextLimits() throws {
        var big = try readyClient()
        #expect(throws: RFBFailure.clipboardTooLarge) { try big.receive(Data([3, 0, 0, 0] + Server.be32(512 * 1024))) }
        var extended = try readyClient()
        #expect(throws: RFBFailure.clipboardTooLarge) { try extended.receive(Data([3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFC])) }
    }

    @Test("colour map entries are skipped without disturbing the stream")
    func colourMapSkipped() throws {
        var client = try readyClient()
        let map: [UInt8] = [1, 0, 0, 0, 0, 2] + [UInt8](repeating: 7, count: 12)
        let step = try client.receive(Data(map) + Data([2]))
        #expect(step.events == [.bell])
    }

    @Test("pointer events clamp to the framebuffer and encode buttons and coordinates")
    func pointerEncoding() {
        let size = RFBSize(width: 100, height: 50)
        #expect(RFBClientMessages.pointer(buttons: 1, x: 10, y: 20, within: size) == Data([5, 1, 0, 10, 0, 20]))
        #expect(RFBClientMessages.pointer(buttons: 0, x: -5, y: 500, within: size) == Data([5, 0, 0, 0, 0, 49]))
        #expect(RFBClientMessages.pointer(buttons: 4, x: 1000, y: 0, within: size) == Data([5, 4, 0, 99, 0, 0]))
    }

    @Test("key events carry the keysym big-endian and map text to keysyms")
    func keyEncoding() {
        #expect(RFBClientMessages.key(0x61, down: true) == Data([4, 1, 0, 0, 0, 0, 0, 0x61]))
        #expect(RFBClientMessages.key(RFBKeysym.backspace, down: false) == Data([4, 0, 0, 0, 0, 0, 0xFF, 0x08]))
        #expect(RFBKeysym.forScalar("a") == 0x61)
        #expect(RFBKeysym.forScalar("é") == 0xE9)
        #expect(RFBKeysym.forScalar("\n") == RFBKeysym.returnKey)
        #expect(RFBKeysym.forScalar("€") == 0x0100_20AC)
    }

    @Test("client clipboard text is Latin-1 with a replacement for other characters and a size cap")
    func clientCutEncoding() {
        #expect(RFBClientMessages.clientCutText("hi") == Data([6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69]))
        #expect(RFBClientMessages.clientCutText("a€") == Data([6, 0, 0, 0, 0, 0, 0, 2, 0x61, 0x3F]))
        #expect(RFBClientMessages.clientCutText(String(repeating: "x", count: 256 * 1024)) == nil)
    }
}
