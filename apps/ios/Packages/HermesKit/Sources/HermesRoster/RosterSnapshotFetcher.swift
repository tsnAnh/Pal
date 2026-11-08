import Foundation
import HermesProtocol
import HermesTransport

public typealias GatewayCall = @Sendable (_ method: String, _ params: JSONValue?) async throws -> JSONValue

public enum RosterSnapshotFetcher {
    public static func fetch(call: @escaping GatewayCall, now: Date = Date()) async throws -> RosterSnapshot {
        let result = try await call("profiles.list", ["include_sessions": true])
        let rows = result["profiles"]?.arrayValue ?? []
        let live = await liveStates(for: rows, call: call)
        try Task.checkCancellation()
        return RosterSnapshot(profiles: rows, live: live, receivedAt: now)
    }

    public static func fetch(on connection: GatewayConnection, now: Date = Date()) async throws -> RosterSnapshot {
        try await fetch(call: { method, params in try await connection.call(method, params: params) }, now: now)
    }

    private static func liveStates(for rows: [JSONValue], call: @escaping GatewayCall) async -> [String: BotLiveState] {
        await withTaskGroup(of: (String, BotLiveState).self) { group in
            for row in rows {
                guard let name = row["name"]?.stringValue else { continue }
                let worker = row["worker_session"]?["last_active"]?.timeIntervalValue
                let onboarding = row["onboarding_pending"]?.boolValue ?? false
                group.addTask {
                    let sessions = await activeSessions(of: name, call: call)
                    return (name, BotLiveState(sessions: sessions, workerLastActive: worker, onboardingPending: onboarding))
                }
            }
            var states: [String: BotLiveState] = [:]
            for await (name, state) in group { states[name] = state }
            return states
        }
    }

    private static func activeSessions(of profile: String, call: GatewayCall) async -> [LiveSessionStatus] {
        guard let result = try? await call("session.active_list", ["profile": .string(profile)]),
              let rows = result["sessions"]?.arrayValue
        else { return [] }
        return rows.map { row in
            row["status"]?.stringValue.flatMap(LiveSessionStatus.init(rawValue:)) ?? .unknown
        }
    }
}

extension RosterSnapshot {
    public func activity(of profile: String, link: GatewayLink = .connected) -> BotActivity? {
        guard profiles.contains(where: { $0["name"]?.stringValue == profile }) else { return nil }
        return BotActivity.derive(link: link, live: live[profile], hasLocalPrompt: false, now: receivedAt)
    }
}

extension JSONValue {
    fileprivate var timeIntervalValue: TimeInterval? {
        switch self {
        case .int(let value): TimeInterval(value)
        case .double(let value): value
        default: nil
        }
    }
}
