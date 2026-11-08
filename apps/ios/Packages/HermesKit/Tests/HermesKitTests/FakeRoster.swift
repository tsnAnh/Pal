import Foundation
import HermesProtocol
import HermesRoster
import HermesTransport
import Synchronization

final class FakeRoster: Sendable {
    struct Profile {
        var uiMeta: [String: JSONValue] = [:]
        var revisions: [String: Int] = [:]
    }

    struct State {
        var names: [String] = []
        var profiles: [String: Profile] = [:]
        var primary = "default"
        var calls: [(method: String, params: JSONValue?)] = []
        var raceOnConfigure: Set<Int> = []
        var failConfigure = 0
        var failCreate = 0
        var denyPrimary = false
        var birthNotice = true
        var configureCount = 0
        var omitRevisions = false
    }

    let state: Mutex<State>

    init(names: [String]) {
        var initial = State()
        initial.names = names
        for name in names { initial.profiles[name] = Profile() }
        state = Mutex(initial)
    }

    func calls(_ method: String) -> [JSONValue?] {
        state.withLock { $0.calls.filter { $0.method == method }.map(\.params) }
    }

    func meta(_ name: String) -> [String: JSONValue]? {
        state.withLock { $0.profiles[name]?.uiMeta[BotMeta.namespace]?.objectValue }
    }

    func revision(_ name: String) -> Int {
        state.withLock { $0.profiles[name]?.revisions[BotMeta.namespace] ?? 0 }
    }

    func seed(_ name: String, meta: [String: JSONValue], revision: Int = 1) {
        state.withLock { state in
            state.profiles[name, default: Profile()].uiMeta[BotMeta.namespace] = .object(meta)
            state.profiles[name, default: Profile()].revisions[BotMeta.namespace] = revision
            if !state.names.contains(name) { state.names.append(name) }
        }
    }

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        state.withLock { state in
            state.calls.append((method, params))
            switch method {
            case "profiles.list": return list(state)
            case "profiles.configure": return configure(&state, params)
            case "profiles.create": return create(&state, params)
            case "profiles.set_primary": return setPrimary(&state, params)
            case "profiles.delete": return delete(&state, params)
            default: return .failure(RPCError(code: -32601, message: "unknown_method"))
            }
        }
    }

    private func list(_ state: State) -> FakeGateway.Reply {
        let rows: [JSONValue] = state.names.map { name in
            let profile = state.profiles[name] ?? Profile()
            var row: [String: JSONValue] = [
                "name": .string(name),
                "is_primary": .bool(name == state.primary),
                "ui_meta": .object(profile.uiMeta),
            ]
            if !state.omitRevisions {
                row["ui_meta_revisions"] = .object(profile.revisions.mapValues { .int($0) })
            }
            return .object(row)
        }
        return .result(["profiles": .array(rows), "bot_birth_notice": .bool(state.birthNotice), "bot_onboarding": true])
    }

    private func configure(_ state: inout State, _ params: JSONValue?) -> FakeGateway.Reply {
        state.configureCount += 1
        if state.failConfigure > 0 {
            state.failConfigure -= 1
            return .failure(RPCError(code: 5064, message: "configure_failed"))
        }
        guard let name = params?["name"]?.stringValue, state.profiles[name] != nil else {
            return .failure(RPCError(code: 4004, message: "not_found"))
        }
        if state.raceOnConfigure.contains(state.configureCount) {
            var current = state.profiles[name]?.uiMeta[BotMeta.namespace]?.objectValue ?? [:]
            current["sneaky"] = true
            state.profiles[name]?.uiMeta[BotMeta.namespace] = .object(current)
            state.profiles[name]?.revisions[BotMeta.namespace, default: 0] += 1
        }
        let incoming = params?["ui_meta"]?.objectValue ?? [:]
        let expected = params?["ui_meta_expected_revisions"]?.objectValue
        let actual = state.profiles[name]?.revisions ?? [:]
        var conflicts: [String: JSONValue] = [:]
        if let expected {
            for key in incoming.keys where expected[key]?.intValue != (actual[key] ?? 0) {
                conflicts[key] = ["expected": expected[key] ?? .null, "actual": .int(actual[key] ?? 0)]
            }
        }
        if !conflicts.isEmpty {
            return .result(["ok": false, "applied": ["ui_meta": false, "ui_meta_conflicts": .object(conflicts)]])
        }
        var revisions: [String: JSONValue] = [:]
        for (key, value) in incoming {
            state.profiles[name]?.uiMeta[key] = value
            state.profiles[name]?.revisions[key, default: 0] += 1
            revisions[key] = .int(state.profiles[name]?.revisions[key] ?? 0)
        }
        return .result(["ok": true, "applied": ["ui_meta": true, "ui_meta_revisions": .object(revisions)]])
    }

    private func create(_ state: inout State, _ params: JSONValue?) -> FakeGateway.Reply {
        if state.failCreate > 0 {
            state.failCreate -= 1
            return .failure(RPCError(code: 5062, message: "create_failed"))
        }
        guard let name = params?["name"]?.stringValue else { return .failure(RPCError(code: 4061, message: "name required")) }
        if state.profiles[name] != nil {
            return .failure(RPCError(code: 4062, message: "A profile named '\(name)' already exists."))
        }
        state.names.append(name)
        state.profiles[name] = Profile()
        return .result(["ok": true, "name": .string(name)])
    }

    private func setPrimary(_ state: inout State, _ params: JSONValue?) -> FakeGateway.Reply {
        if state.denyPrimary { return .failure(RPCError(code: 4403, message: "permission_denied")) }
        guard let name = params?["name"]?.stringValue, state.profiles[name] != nil else {
            return .failure(RPCError(code: 4004, message: "not_found"))
        }
        state.primary = name
        return .result(["ok": true, "name": .string(name)])
    }

    private func delete(_ state: inout State, _ params: JSONValue?) -> FakeGateway.Reply {
        guard let name = params?["name"]?.stringValue, state.profiles[name] != nil else {
            return .failure(RPCError(code: 4004, message: "not_found"))
        }
        state.profiles[name] = nil
        state.names.removeAll { $0 == name }
        return .result(["ok": true, "name": .string(name)])
    }
}

func rosterGateway(_ fake: FakeGateway) async throws -> (RosterGateway, GatewayConnection) {
    let connection = try await GatewayConnection.dial(url: fake.url, ticket: "t")
    return (RosterGateway(connection: connection), connection)
}
