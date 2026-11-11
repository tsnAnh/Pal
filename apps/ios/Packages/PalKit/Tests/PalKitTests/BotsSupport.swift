import Foundation
import PalBotProfile
import PalProtocol
import Synchronization

final class ScriptedBots: Sendable {
    struct Call: Sendable, Equatable {
        var method: String
        var params: [String: JSONValue]
    }

    typealias Handler = @Sendable ([String: JSONValue]) throws -> JSONValue

    private let handlers = Mutex<[String: [Handler]]>([:])
    private let log = Mutex<[Call]>([])

    var calls: [Call] { log.withLock { $0 } }

    func script(_ method: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[method, default: []].append(handler) }
    }

    func script(_ method: String, _ result: JSONValue) {
        script(method) { _ in result }
    }

    func calls(to method: String) -> [Call] {
        calls.filter { $0.method == method }
    }

    var gateway: BotsGateway {
        BotsGateway { [self] method, params in
            let object = params?.objectValue ?? [:]
            log.withLock { $0.append(Call(method: method, params: object)) }
            let next: Handler? = handlers.withLock { table in
                guard var queue = table[method], !queue.isEmpty else { return nil }
                let first = queue.count > 1 ? queue.removeFirst() : queue[0]
                table[method] = queue
                return first
            }
            guard let next else { throw ScriptError.unscripted(method) }
            return try next(object)
        }
    }

    enum ScriptError: Error {
        case unscripted(String)
    }
}

func profileRow(
    _ name: String,
    primary: Bool = false,
    routines: Int? = nil,
    meta: [String: JSONValue]? = nil,
    revision: Int? = nil,
    displayName: String = ""
) -> JSONValue {
    var row: [String: JSONValue] = ["name": .string(name), "is_primary": .bool(primary), "display_name": .string(displayName)]
    if let routines { row["routines_enabled"] = .int(routines) }
    if let meta { row["ui_meta"] = ["hermes-bots": .object(meta)] }
    if let revision { row["ui_meta_revisions"] = ["hermes-bots": .int(revision)] }
    return .object(row)
}

func profilesList(_ rows: JSONValue...) -> JSONValue {
    ["profiles": .array(rows)]
}
