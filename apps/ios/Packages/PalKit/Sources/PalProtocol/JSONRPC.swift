import Foundation
import PalDiagnostics

public enum RPCID: Sendable, Hashable, Codable {
    case int(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct RPCError: Error, Sendable, Hashable, Codable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

extension RPCError {
    public var reasonCode: String? {
        guard let reason = data?["reason"]?.stringValue, !reason.isEmpty, reason.count <= 64,
              reason.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "_" })
        else { return nil }
        return reason
    }
}

extension RPCError: DiagnosticSummarizing {
    public var diagnosticSummary: String {
        reasonCode.map { "RPCError code=\(code) reason=\($0)" } ?? "RPCError code=\(code)"
    }
}

public struct RPCRequest: Sendable, Hashable {
    public var id: RPCID
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCResponse: Sendable, Hashable {
    public var id: RPCID?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: RPCID?, result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct RPCNotification: Sendable, Hashable {
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public enum RPCMessage: Sendable, Hashable {
    case request(RPCRequest)
    case response(RPCResponse)
    case notification(RPCNotification)
}

public enum RPCCodecError: Error, Sendable, Equatable {
    case notAnObject
    case wrongVersion
    case malformed
    case batchUnsupported
}

public enum RPCCodec {
    public static let version = "2.0"

    public static func encode(_ request: RPCRequest) throws -> Data {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "method": .string(request.method),
            "id": try idValue(request.id),
        ]
        if let params = request.params { object["params"] = params }
        return try encoder.encode(JSONValue.object(object))
    }

    public static func encode(_ response: RPCResponse) throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": .string(version)]
        object["id"] = try response.id.map(idValue) ?? .null
        if let error = response.error {
            var errorObject: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
            if let data = error.data { errorObject["data"] = data }
            object["error"] = .object(errorObject)
        } else {
            object["result"] = response.result ?? .null
        }
        return try encoder.encode(JSONValue.object(object))
    }

    public static func encode(_ notification: RPCNotification) throws -> Data {
        var object: [String: JSONValue] = [
            "jsonrpc": .string(version),
            "method": .string(notification.method),
        ]
        if let params = notification.params { object["params"] = params }
        return try encoder.encode(JSONValue.object(object))
    }

    public static func decode(_ data: Data) throws -> RPCMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            if case .array = value { throw RPCCodecError.batchUnsupported }
            throw RPCCodecError.notAnObject
        }
        guard object["jsonrpc"]?.stringValue == version else { throw RPCCodecError.wrongVersion }
        let id = try object["id"].flatMap(rpcID)
        if let method = object["method"]?.stringValue {
            if let id {
                return .request(RPCRequest(id: id, method: method, params: object["params"]))
            }
            return .notification(RPCNotification(method: method, params: object["params"]))
        }
        if let errorValue = object["error"], case .object(let errorObject) = errorValue {
            guard let code = errorObject["code"]?.intValue, let message = errorObject["message"]?.stringValue else {
                throw RPCCodecError.malformed
            }
            return .response(RPCResponse(id: id, error: RPCError(code: code, message: message, data: errorObject["data"])))
        }
        guard object.keys.contains("result") else { throw RPCCodecError.malformed }
        return .response(RPCResponse(id: id, result: object["result"]))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private static func idValue(_ id: RPCID) throws -> JSONValue {
        switch id {
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        }
    }

    private static func rpcID(_ value: JSONValue) throws -> RPCID? {
        switch value {
        case .null: nil
        case .int(let value): .int(value)
        case .string(let value): .string(value)
        default: throw RPCCodecError.malformed
        }
    }
}

public struct GatewayEvent: Sendable, Hashable {
    public var type: String
    public var payload: JSONValue?
    public var sessionID: String?
    public var seq: Int?
    public var replayEpoch: String?
    public var executionGeneration: Int?
    public var admissionID: String?

    public init(
        type: String,
        payload: JSONValue? = nil,
        sessionID: String? = nil,
        seq: Int? = nil,
        replayEpoch: String? = nil,
        executionGeneration: Int? = nil,
        admissionID: String? = nil
    ) {
        self.type = type
        self.payload = payload
        self.sessionID = sessionID
        self.seq = seq
        self.replayEpoch = replayEpoch
        self.executionGeneration = executionGeneration
        self.admissionID = admissionID
    }

    public init?(params: JSONValue?) {
        guard let params, let type = params["type"]?.stringValue else { return nil }
        self.init(
            type: type,
            payload: params["payload"],
            sessionID: params["session_id"]?.stringValue,
            seq: params["seq"]?.intValue,
            replayEpoch: params["replay_epoch"]?.stringValue,
            executionGeneration: params["execution_generation"]?.intValue,
            admissionID: params["admission_id"]?.stringValue
        )
    }

    public init?(notification: RPCNotification) {
        guard notification.method == "event" else { return nil }
        self.init(params: notification.params)
    }
}
