import Foundation

struct ByteQueue {
    private var bytes: [UInt8] = []
    private var head = 0

    var count: Int { bytes.count - head }

    mutating func append(_ data: Data) {
        if head > 0, head >= bytes.count / 2 {
            bytes.removeFirst(head)
            head = 0
        }
        bytes.append(contentsOf: data)
    }

    func byte(at offset: Int) -> UInt8 { bytes[head + offset] }

    func uint16(at offset: Int) -> Int { Int(byte(at: offset)) << 8 | Int(byte(at: offset + 1)) }

    func int32(at offset: Int) -> Int32 {
        let value = UInt32(byte(at: offset)) << 24 | UInt32(byte(at: offset + 1)) << 16
            | UInt32(byte(at: offset + 2)) << 8 | UInt32(byte(at: offset + 3))
        return Int32(bitPattern: value)
    }

    func slice(_ offset: Int, _ length: Int) -> [UInt8] {
        Array(bytes[head + offset ..< head + offset + length])
    }

    mutating func consume(_ length: Int) {
        head += length
        if head == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            head = 0
        }
    }
}

public struct RFBClient: Sendable {
    public static let maximumNameBytes = 4096
    public static let maximumServerCutBytes = 256 * 1024
    static let maximumRawBytes = 128 * 1024 * 1024
    private static let serverInitHeader = 24

    private enum Phase: Sendable {
        case version
        case securityTypes(RFBVersion)
        case securityResult
        case serverInit
        case running
        case failed(RFBFailure)
    }

    private enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
    }

    private struct PendingRect {
        var rect: RFBRect
        var encoding: Encoding
        var payloadOffset: Int
    }

    private var queue = ByteQueue()
    private var phase = Phase.version
    public private(set) var framebuffer = RFBFramebuffer(size: RFBSize(width: 1, height: 1))

    public init() {}

    public mutating func receive(_ data: Data) throws -> RFBStep {
        if case .failed(let failure) = phase { throw failure }
        queue.append(data)
        var step = RFBStep()
        do {
            while try advance(&step) {}
        } catch let failure as RFBFailure {
            phase = .failed(failure)
            throw failure
        }
        return step
    }

    private mutating func advance(_ step: inout RFBStep) throws -> Bool {
        switch phase {
        case .version: try readVersion(&step)
        case .securityTypes(let version): try readSecurityTypes(version, &step)
        case .securityResult: try readSecurityResult(&step)
        case .serverInit: try readServerInit(&step)
        case .running: try readServerMessage(&step)
        case .failed(let failure): throw failure
        }
    }

    private mutating func readVersion(_ step: inout RFBStep) throws -> Bool {
        guard queue.count >= 12 else { return false }
        guard let version = RFBVersion(banner: queue.slice(0, 12)) else { throw RFBFailure.unsupportedVersion }
        queue.consume(12)
        step.replies.append(RFBClientMessages.version(version))
        phase = .securityTypes(version)
        return true
    }

    private mutating func readSecurityTypes(_ version: RFBVersion, _ step: inout RFBStep) throws -> Bool {
        guard queue.count >= 1 else { return false }
        let count = Int(queue.byte(at: 0))
        if count == 0 { throw RFBFailure.securityRefused }
        guard queue.count >= 1 + count else { return false }
        let offered = queue.slice(1, count)
        guard offered.contains(1) else { throw RFBFailure.unsupportedSecurity }
        queue.consume(1 + count)
        step.replies.append(RFBClientMessages.noneSecurityChoice)
        switch version {
        case .v38:
            phase = .securityResult
        case .v37:
            step.replies.append(RFBClientMessages.sharedClientInit)
            phase = .serverInit
        }
        return true
    }

    private mutating func readSecurityResult(_ step: inout RFBStep) throws -> Bool {
        guard queue.count >= 4 else { return false }
        guard queue.int32(at: 0) == 0 else { throw RFBFailure.securityRefused }
        queue.consume(4)
        step.replies.append(RFBClientMessages.sharedClientInit)
        phase = .serverInit
        return true
    }

    private mutating func readServerInit(_ step: inout RFBStep) throws -> Bool {
        guard queue.count >= Self.serverInitHeader else { return false }
        let width = queue.uint16(at: 0)
        let height = queue.uint16(at: 2)
        let nameLength = Int(UInt32(bitPattern: queue.int32(at: 20)))
        guard Self.isValid(width: width, height: height), nameLength <= Self.maximumNameBytes else {
            throw RFBFailure.invalidServerInit
        }
        guard queue.count >= Self.serverInitHeader + nameLength else { return false }
        let name = String(decoding: queue.slice(Self.serverInitHeader, nameLength), as: UTF8.self)
        queue.consume(Self.serverInitHeader + nameLength)
        let size = RFBSize(width: width, height: height)
        framebuffer = RFBFramebuffer(size: size)
        step.replies.append(RFBClientMessages.setPixelFormat())
        step.replies.append(RFBClientMessages.setEncodings())
        step.replies.append(fullUpdateRequest(incremental: false))
        step.events.append(.ready(size, name: name))
        phase = .running
        return true
    }

    private mutating func readServerMessage(_ step: inout RFBStep) throws -> Bool {
        guard queue.count >= 1 else { return false }
        switch queue.byte(at: 0) {
        case 0: return try readFramebufferUpdate(&step)
        case 1: return readColourMap()
        case 2:
            queue.consume(1)
            step.events.append(.bell)
            return true
        case 3: return try readServerCutText(&step)
        case let other: throw RFBFailure.unsupportedMessage(other)
        }
    }

    private mutating func readColourMap() -> Bool {
        guard queue.count >= 6 else { return false }
        let total = 6 + queue.uint16(at: 4) * 6
        guard queue.count >= total else { return false }
        queue.consume(total)
        return true
    }

    private mutating func readServerCutText(_ step: inout RFBStep) throws -> Bool {
        guard queue.count >= 8 else { return false }
        let declared = queue.int32(at: 4)
        guard declared >= 0, Int(declared) <= Self.maximumServerCutBytes else { throw RFBFailure.clipboardTooLarge }
        let length = Int(declared)
        guard queue.count >= 8 + length else { return false }
        let text = String(String.UnicodeScalarView(queue.slice(8, length).map { Unicode.Scalar($0) }))
        queue.consume(8 + length)
        step.events.append(.serverCutText(text))
        return true
    }

    private mutating func readFramebufferUpdate(_ step: inout RFBStep) throws -> Bool {
        guard queue.count >= 4 else { return false }
        let rectCount = queue.uint16(at: 2)
        var offset = 4
        var pending: [PendingRect] = []
        for _ in 0..<rectCount {
            guard queue.count >= offset + 12 else { return false }
            let rect = RFBRect(x: queue.uint16(at: offset), y: queue.uint16(at: offset + 2),
                               width: queue.uint16(at: offset + 4), height: queue.uint16(at: offset + 6))
            let code = queue.int32(at: offset + 8)
            guard let encoding = Encoding(rawValue: code) else { throw RFBFailure.unsupportedEncoding(code) }
            offset += 12
            let payload = try payloadLength(of: rect, encoding: encoding)
            guard queue.count >= offset + payload else { return false }
            pending.append(PendingRect(rect: rect, encoding: encoding, payloadOffset: offset))
            offset += payload
        }
        try apply(pending, &step)
        queue.consume(offset)
        return true
    }

    private func payloadLength(of rect: RFBRect, encoding: Encoding) throws -> Int {
        switch encoding {
        case .raw:
            let bytes = rect.width * rect.height * RFBFramebuffer.bytesPerPixel
            guard bytes <= Self.maximumRawBytes else { throw RFBFailure.rectangleOutOfBounds }
            return bytes
        case .copyRect: return 4
        case .desktopSize: return 0
        }
    }

    private mutating func apply(_ pending: [PendingRect], _ step: inout RFBStep) throws {
        var dirty: [RFBRect] = []
        var resized = false
        for item in pending {
            switch item.encoding {
            case .raw:
                guard framebuffer.contains(item.rect) else { throw RFBFailure.rectangleOutOfBounds }
                let bytes = queue.slice(item.payloadOffset, item.rect.width * item.rect.height * RFBFramebuffer.bytesPerPixel)
                framebuffer.paint(item.rect, from: bytes, at: 0)
                dirty.append(item.rect)
            case .copyRect:
                let sourceX = queue.uint16(at: item.payloadOffset)
                let sourceY = queue.uint16(at: item.payloadOffset + 2)
                let source = RFBRect(x: sourceX, y: sourceY, width: item.rect.width, height: item.rect.height)
                guard framebuffer.contains(item.rect), framebuffer.contains(source) else { throw RFBFailure.rectangleOutOfBounds }
                framebuffer.copy(item.rect, fromX: sourceX, y: sourceY)
                dirty.append(item.rect)
            case .desktopSize:
                guard Self.isValid(width: item.rect.width, height: item.rect.height) else { throw RFBFailure.invalidServerInit }
                let size = RFBSize(width: item.rect.width, height: item.rect.height)
                framebuffer.resize(to: size)
                dirty.removeAll()
                resized = true
                step.events.append(.resized(size))
            }
        }
        if !dirty.isEmpty { step.events.append(.updated(dirty)) }
        step.replies.append(fullUpdateRequest(incremental: !resized))
    }

    private func fullUpdateRequest(incremental: Bool) -> Data {
        RFBClientMessages.updateRequest(
            incremental: incremental, x: 0, y: 0, width: framebuffer.size.width, height: framebuffer.size.height
        )
    }

    private static func isValid(width: Int, height: Int) -> Bool {
        (1...RFBFramebuffer.maximumDimension).contains(width) && (1...RFBFramebuffer.maximumDimension).contains(height)
    }
}
