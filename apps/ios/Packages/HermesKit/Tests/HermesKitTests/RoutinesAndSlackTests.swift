import Foundation
import HermesBotProfile
import HermesDiagnostics
import HermesProtocol
import HermesTransport
import Synchronization
import Testing

@Suite("Routines")
struct RoutineTests {
    private func job(_ id: String, name: String, text: String?, zone: String?, enabled: Bool = true) -> JSONValue {
        var row: [String: JSONValue] = ["job_id": .string(id), "name": .string(name), "enabled": .bool(enabled)]
        if let text { row["schedule_text"] = .string(text) }
        if let zone { row["schedule_timezone"] = .string(zone) }
        return .object(row)
    }

    @Test("listing asks for paused routines too and maps schedule, zone and state")
    func listing() async throws {
        let bots = ScriptedBots()
        bots.script("cron.manage", ["success": true, "jobs": [
            job("a1", name: "Canh thanh toán", text: "Weekdays around 8:30 AM", zone: "Asia/Ho_Chi_Minh"),
            job("b2", name: "Review", text: nil, zone: nil, enabled: false),
        ]])
        let routines = try await RoutineService(gateway: bots.gateway).list(profile: "a")
        #expect(routines.map(\.id) == ["a1", "b2"])
        #expect(routines.map(\.isEnabled) == [true, false])
        #expect(bots.calls.first?.params == ["action": "list", "include_disabled": true, "profile": "a"])
    }

    @Test("caption joins the schedule with the generic zone name")
    func caption() {
        let english = Locale(identifier: "en_US")
        #expect(ScheduleCaption.text(scheduleText: "Weekdays around 8:30 AM", timeZoneID: "Asia/Ho_Chi_Minh", locale: english) == "Weekdays around 8:30 AM (Indochina)")
        #expect(ScheduleCaption.text(scheduleText: "Every day around 9:00 AM", timeZoneID: "America/New_York", locale: english) == "Every day around 9:00 AM (Eastern)")
    }

    @Test("caption omits an unknown zone and names a missing schedule as custom")
    func captionFallbacks() {
        let english = Locale(identifier: "en_US")
        #expect(ScheduleCaption.text(scheduleText: "Every hour", timeZoneID: "Mars/Olympus", locale: english) == "Every hour")
        #expect(ScheduleCaption.text(scheduleText: "Every hour", timeZoneID: nil, locale: english) == "Every hour")
        #expect(ScheduleCaption.text(scheduleText: "  ", timeZoneID: "Asia/Ho_Chi_Minh", locale: english) == "Custom schedule (Indochina)")
        #expect(ScheduleCaption.text(scheduleText: nil, timeZoneID: "", locale: english) == "Custom schedule")
    }

    @Test("pause and resume address the job and fail on a tool error")
    func toggle() async throws {
        let bots = ScriptedBots()
        bots.script("cron.manage", ["success": true, "job": job("a1", name: "x", text: nil, zone: nil, enabled: false)])
        let service = RoutineService(gateway: bots.gateway)
        try await service.setEnabled(false, routine: "a1", profile: "a")
        try await service.setEnabled(true, routine: "a1", profile: "a")
        let actions = bots.calls.map { $0.params["action"] }
        #expect(actions == ["pause", "resume"])
        #expect(bots.calls[0].params["name"] == "a1")

        let failing = ScriptedBots()
        failing.script("cron.manage", ["success": false, "error": "That routine no longer exists."])
        await #expect(throws: RoutineError.failed) {
            try await RoutineService(gateway: failing.gateway).setEnabled(true, routine: "gone", profile: "a")
        }
    }

    @Test("remove addresses the job and fails on a tool error")
    func remove() async throws {
        let bots = ScriptedBots()
        bots.script("cron.manage", ["success": true, "removed_job": ["id": "a1"]])
        try await RoutineService(gateway: bots.gateway).remove(routine: "a1", profile: "a")
        #expect(bots.calls.first?.params["action"] == "remove")
        let failing = ScriptedBots()
        failing.script("cron.manage", ["success": false, "error": "nope"])
        await #expect(throws: RoutineError.failed) {
            try await RoutineService(gateway: failing.gateway).remove(routine: "a1", profile: "a")
        }
    }

    @Test("preview returns the accepted phrase and next run")
    func preview() async throws {
        let bots = ScriptedBots()
        bots.script("cron.manage", ["success": true, "schedule": "30 8 * * 1-5", "accepted_as": "every weekdays at 8:30am", "kind": "cron", "next_run_at": "2026-11-05T08:30:00+07:00"])
        let preview = try await RoutineService(gateway: bots.gateway).preview(schedule: "weekdays at 8:30am", profile: "a")
        #expect(preview.acceptedAs == "every weekdays at 8:30am")
        #expect(preview.nextRun != nil)
        #expect(bots.calls.first?.params["action"] == "schedule_preview")
    }

    @Test("a refused schedule carries its stable reason")
    func previewRefusal() async {
        for (reason, expected) in [("too_frequent", ScheduleRefusal.tooFrequent), ("empty", .empty), ("unrecognized", .unrecognized), ("weird", .invalid)] {
            let bots = ScriptedBots()
            bots.script("cron.manage", ["success": false, "error": "x", "reason": .string(reason)])
            await #expect(throws: RoutineError.scheduleRefused(expected)) {
                _ = try await RoutineService(gateway: bots.gateway).preview(schedule: "x", profile: "a")
            }
        }
    }

    @Test("adding a routine delivers into the bot chat")
    func add() async throws {
        let bots = ScriptedBots()
        bots.script("cron.manage", ["success": true, "job": job("n1", name: "Morning brief", text: nil, zone: nil)])
        let routine = try await RoutineService(gateway: bots.gateway).add(title: "Morning brief", prompt: "Summarise", schedule: "weekdays at 8:30am", profile: "a")
        #expect(routine.id == "n1")
        #expect(bots.calls.first?.params == [
            "action": "add", "name": "Morning brief", "prompt": "Summarise", "schedule": "weekdays at 8:30am",
            "deliver": "bot-chat", "profile": "a",
        ])
    }

    @Test("adding with a refused schedule or a tool error fails distinctly")
    func addFailures() async {
        let refused = ScriptedBots()
        refused.script("cron.manage", ["success": false, "error": "x", "reason": "unrecognized"])
        await #expect(throws: RoutineError.scheduleRefused(.unrecognized)) {
            try await RoutineService(gateway: refused.gateway).add(title: "t", prompt: "p", schedule: "s", profile: "a")
        }
        let failed = ScriptedBots()
        failed.script("cron.manage", ["success": false, "error": "disk full"])
        await #expect(throws: RoutineError.failed) {
            try await RoutineService(gateway: failed.gateway).add(title: "t", prompt: "p", schedule: "s", profile: "a")
        }
    }
}

@Suite("Slack connection")
struct SlackTests {
    private func status(
        configured: Bool = true,
        state: String? = nil,
        restartStarted: Bool? = nil,
        restartBusy: Bool? = nil,
        restartError: String? = nil
    ) throws -> SlackConnection {
        var object: [String: JSONValue] = ["enabled": .bool(configured), "configured": .bool(configured), "gateway_running": true]
        if let state { object["state"] = .string(state) }
        if let restartStarted { object["restart_started"] = .bool(restartStarted) }
        if let restartBusy { object["restart_busy"] = .bool(restartBusy) }
        if let restartError { object["restart_error"] = .string(restartError) }
        return SlackConnection(try JSONValue.object(object).decoded(as: SlackStatusWire.self))
    }

    @Test("status maps to connected, not connected, restart needed and failed")
    func mapping() throws {
        #expect(try status(state: "connected") == .connected)
        #expect(try status(configured: false, state: "not_configured") == .notConnected)
        #expect(try status(state: "disabled") == .notConnected)
        #expect(try status(state: "pending_restart") == .restartNeeded)
        #expect(try status(state: "gateway_stopped") == .restartNeeded)
        #expect(try status(state: "pending_restart", restartStarted: true) == .starting)
        #expect(try status(state: "startup_failed") == .failed)
        #expect(try status(state: "pending_restart", restartBusy: true) == .restartNeeded)
        #expect(try status(state: "connected", restartError: "boom") == .failed)
        #expect(try status(state: "something_new") == .starting)
    }

    @Test("only the starting state keeps polling")
    func settled() {
        #expect(SlackConnection.starting.isSettled == false)
        for settled in [SlackConnection.connected, .notConnected, .restartNeeded, .failed] { #expect(settled.isSettled) }
    }

    @Test("tokens need the xoxb and xapp prefixes and no whitespace")
    func tokenValidation() {
        #expect(SlackTokens(bot: "xoxb-123", app: "xapp-456") != nil)
        #expect(SlackTokens(bot: " xoxb-123 \n", app: "xapp-456") != nil)
        #expect(SlackTokens(bot: "xoxp-123", app: "xapp-456") == nil)
        #expect(SlackTokens(bot: "xoxb-123", app: "xoxb-456") == nil)
        #expect(SlackTokens(bot: "xoxb-", app: "xapp-456") == nil)
        #expect(SlackTokens(bot: "xoxb-1 2", app: "xapp-456") == nil)
        #expect(SlackTokens(bot: "", app: "") == nil)
    }

    @Test("manifest passes the bot name and accepts only an api.slack.com https link")
    func manifest() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.slack.manifest", ["profile": "a", "bot_name": "chó UA", "manifest": [:], "create_url": "https://api.slack.com/apps?new_app=1&manifest_json=%7B%7D"])
        let manifest = try await SlackService(gateway: bots.gateway).manifest(profile: "a", displayName: "chó UA")
        #expect(manifest.createURL.host() == "api.slack.com")
        #expect(bots.calls.first?.params == ["profile": "a", "display_name": "chó UA"])

        for hostile in ["http://api.slack.com/apps", "https://evil.example/apps", "javascript:alert(1)", "not a url"] {
            let bad = ScriptedBots()
            bad.script("messaging.slack.manifest", ["profile": "a", "bot_name": "x", "manifest": [:], "create_url": .string(hostile)])
            await #expect(throws: BotsError.invalidResponse) {
                _ = try await SlackService(gateway: bad.gateway).manifest(profile: "a", displayName: "x")
            }
        }
    }

    @Test("connect sends both tokens to the named bot and reports the resulting state")
    func connect() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.slack.connect", [
            "profile": "a", "enabled": true, "configured": true, "gateway_running": true, "state": "pending_restart",
            "hot_served": false, "restart_started": false, "restart_busy": true,
        ])
        let tokens = try #require(SlackTokens(bot: "xoxb-secret-one", app: "xapp-secret-two"))
        let state = try await SlackService(gateway: bots.gateway).connect(profile: "a", tokens: tokens)
        #expect(state == .restartNeeded)
        #expect(bots.calls.first?.params == ["bot_token": "xoxb-secret-one", "app_token": "xapp-secret-two", "profile": "a"])
    }

    @Test("a refused connect never leaks the tokens into diagnostics or the error")
    func connectRefusal() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.slack.connect") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4101, message: "SLACK_BOT_TOKEN rejected"))
        }
        let tokens = try #require(SlackTokens(bot: "xoxb-secret-one", app: "xapp-secret-two"))
        do {
            _ = try await SlackService(gateway: bots.gateway).connect(profile: "a", tokens: tokens)
            Issue.record("expected a refusal")
        } catch let error as BotsError {
            #expect(error == .rejected(reason: SlackService.invalidTokensReason))
            #expect(!String(describing: error).contains("secret"))
        }
    }

    @Test("a failed save is a plain rejection, not an invalid-token verdict")
    func connectFailure() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.slack.connect") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 5102, message: "Could not save the Slack connection"))
        }
        let tokens = try #require(SlackTokens(bot: "xoxb-a", app: "xapp-b"))
        await #expect(throws: BotsError.rejected(reason: nil)) {
            _ = try await SlackService(gateway: bots.gateway).connect(profile: "a", tokens: tokens)
        }
    }

    @Test("disconnect and status address the named bot")
    func disconnect() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.slack.disconnect", ["profile": "a", "enabled": false, "configured": false, "gateway_running": true, "state": "not_configured", "hot_served": true, "restart_started": false])
        bots.script("messaging.slack.status", ["profile": "a", "enabled": true, "configured": true, "gateway_running": true, "state": "connected"])
        let service = SlackService(gateway: bots.gateway)
        #expect(try await service.disconnect(profile: "a") == .notConnected)
        #expect(try await service.status(profile: "a") == .connected)
        #expect(bots.calls.map(\.params["profile"]) == ["a", "a"])
    }
}
