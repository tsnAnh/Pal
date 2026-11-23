import Foundation
import PalBotProfile
import PalProtocol
import Testing

@Suite("Slack status mapping")
struct SlackStatusMappingTests {
    private func status(
        configured: Bool = true,
        enabled: Bool? = nil,
        gatewayRunning: Bool = true,
        state: String? = nil,
        errorCode: String? = nil,
        restartError: String? = nil
    ) throws -> SlackStatus {
        var object: [String: JSONValue] = [
            "enabled": .bool(enabled ?? configured), "configured": .bool(configured), "gateway_running": .bool(gatewayRunning),
        ]
        if let state { object["state"] = .string(state) }
        if let errorCode { object["error_code"] = .string(errorCode) }
        if let restartError { object["restart_error"] = .string(restartError) }
        return SlackStatus(try JSONValue.object(object).decoded(as: SlackStatusWire.self))
    }

    @Test("every state the gateway reports is either settled or a bounded coming-up state")
    func gatewayStates() throws {
        for state in ["connecting", "pending_restart", "gateway_stopped"] {
            #expect(try status(state: state).connection == .starting, "\(state)")
        }
        for state in ["startup_failed", "disconnected", "paused"] {
            #expect(try status(state: state).connection == .failed, "\(state)")
        }
        #expect(try status(state: "connected").connection == .connected)
        #expect(try status(state: "disabled").connection == .notConnected)
        #expect(try status(configured: false, state: "not_configured").connection == .notConnected)
    }

    @Test("an unknown or missing state settles when the gateway is down or the adapter is off")
    func unknownState() throws {
        for state: String? in [nil, "", "something_new", "stopped"] {
            let label = state ?? "nil"
            #expect(try status(gatewayRunning: false, state: state).connection == .failed, "\(label)")
            #expect(try status(enabled: false, state: state).connection == .notConnected, "\(label)")
            #expect(try status(state: state).connection == .starting, "\(label)")
        }
        let down = try status(gatewayRunning: false)
        #expect(down.connection.isSettled)
        #expect(down.detail == "This bot isn't running, so Slack can't start. Try again.")
    }

    @Test("a failed status explains itself without an error code, and an error code wins")
    func failedDetail() throws {
        #expect(try status(state: "startup_failed").detail == "Pal couldn't start Slack for this bot. Try again, or update the tokens.")
        #expect(try status(state: "disconnected").detail == "Slack disconnected. Try again.")
        #expect(try status(state: "paused").detail == "Slack was paused after repeated failures. Try again, or update the tokens.")
        #expect(try status(state: "connected", restartError: "boom").detail?.contains("restart") == true)
        #expect(try status(state: "fatal", errorCode: "invalid_auth").detail?.hasPrefix("Slack didn't accept a token") == true)
        #expect(try status(state: "connected").detail == nil)
        #expect(try status(state: "pending_restart").detail == nil)
    }

    @Test("the stalled reason names the bot and the last state in plain words")
    func stalledReason() {
        let cases: [(String?, String)] = [
            ("gateway_stopped", "the bot isn't running"), ("pending_restart", "waiting for the bot to restart"),
            ("connecting", "connecting"), ("retrying", "retrying"), (nil, "no status yet"), ("", "no status yet"),
            ("new_thing", "new thing"), ("xoxb-1 leak", "unknown"),
        ]
        for (state, label) in cases {
            let stalled = SlackStatus.stalled(last: SlackStatus(connection: .starting, state: state), botName: "Manifest Bot")
            #expect(stalled.connection == .failed)
            #expect(stalled.detail == "Slack hasn't started for Manifest Bot. Last status: \(label).", "\(state ?? "nil")")
        }
    }
}
