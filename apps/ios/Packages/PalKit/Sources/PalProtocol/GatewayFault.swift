import Foundation

public struct TraceID: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public init?(_ rawValue: String) {
        guard (1...16).contains(rawValue.count),
              rawValue.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) })
        else { return nil }
        self.rawValue = rawValue
    }

    public static func random() -> TraceID {
        var generator = SystemRandomNumberGenerator()
        return TraceID(rawValue: String((0..<8).map { _ in alphabet.randomElement(using: &generator)! }))
    }

    private init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

public struct GatewayFault: Error, Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case gateway
        case transport
        case decode
    }

    public var code: Int?
    public var reason: String
    public var trace: TraceID
    public var method: String
    public var source: Source
    public var gatewayVersion: String?

    public init(code: Int?, reason: String, trace: TraceID, method: String, source: Source, gatewayVersion: String? = nil) {
        self.code = code
        self.reason = reason
        self.trace = trace
        self.method = method
        self.source = source
        self.gatewayVersion = gatewayVersion
    }

    public init(_ rpc: RPCError, method: String) {
        self.init(code: rpc.code, reason: rpc.reasonCode ?? "internal", trace: rpc.trace ?? .random(), method: method,
                  source: .gateway, gatewayVersion: rpc.gatewayVersion)
    }

    public static func transport(_ reason: String, method: String, trace: TraceID = .random()) -> GatewayFault {
        GatewayFault(code: nil, reason: reason, trace: trace, method: method, source: .transport)
    }

    public static func decode(method: String, trace: TraceID = .random()) -> GatewayFault {
        GatewayFault(code: nil, reason: "decode", trace: trace, method: method, source: .decode)
    }

    public var detailsLine: String {
        [reason, "trace \(trace)", gatewayVersion.map { "gateway \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

extension RPCError {
    public var trace: TraceID? { data?["trace"]?.stringValue.flatMap(TraceID.init) }

    public var gatewayVersion: String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+")
        guard let version = data?["gateway_version"]?.stringValue, !version.isEmpty, version.count <= 32,
              version.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return version
    }
}
