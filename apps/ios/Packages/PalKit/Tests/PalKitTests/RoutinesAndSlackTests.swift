import Foundation
import PalBotProfile
import PalDiagnostics
import PalProtocol
import PalTransport
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
        restartError: String? = nil,
        errorCode: String? = nil,
        neededScope: String? = nil,
        providedScope: String? = nil
    ) throws -> SlackStatus {
        var object: [String: JSONValue] = ["enabled": .bool(configured), "configured": .bool(configured), "gateway_running": true]
        if let state { object["state"] = .string(state) }
        if let restartStarted { object["restart_started"] = .bool(restartStarted) }
        if let restartBusy { object["restart_busy"] = .bool(restartBusy) }
        if let restartError { object["restart_error"] = .string(restartError) }
        if let errorCode { object["error_code"] = .string(errorCode) }
        if let neededScope { object["needed_scope"] = .string(neededScope) }
        if let providedScope { object["provided_scope"] = .string(providedScope) }
        return SlackStatus(try JSONValue.object(object).decoded(as: SlackStatusWire.self))
    }

    private func connection(
        _ state: String?,
        errorCode: String? = nil,
        configured: Bool = true
    ) throws -> SlackConnection {
        try status(configured: configured, state: state, errorCode: errorCode).connection
    }

    @Test("status maps to connected, not connected, restart needed and failed")
    func mapping() throws {
        #expect(try connection("connected") == .connected)
        #expect(try connection("not_configured", configured: false) == .notConnected)
        #expect(try connection("disabled") == .notConnected)
        #expect(try connection("pending_restart") == .restartNeeded)
        #expect(try connection("gateway_stopped") == .restartNeeded)
        #expect(try status(state: "pending_restart", restartStarted: true).connection == .starting)
        #expect(try connection("startup_failed") == .failed)
        #expect(try status(state: "pending_restart", restartBusy: true).connection == .restartNeeded)
        #expect(try status(state: "connected", restartError: "boom").connection == .failed)
        #expect(try connection("something_new") == .starting)
    }

    @Test("fatal and retrying with an error code are failures, without one they keep starting")
    func failureStates() throws {
        for state in ["fatal", "retrying", "startup_failed"] {
            #expect(try connection(state, errorCode: "missing_scope") == .failed, "\(state)")
        }
        #expect(try connection("fatal") == .starting)
        #expect(try connection("retrying") == .starting)
        #expect(try connection("retrying", errorCode: "") == .starting)
        #expect(try connection("connected", errorCode: "missing_scope") == .connected)
        #expect(try connection("fatal", errorCode: "invalid_auth").isSettled)
    }

    @Test("token update is offered only for failed and connected")
    func updateRule() {
        let offered: [SlackConnection] = [.failed, .connected]
        let hidden: [SlackConnection] = [.notConnected, .starting, .restartNeeded]
        for connection in offered { #expect(connection.allowsTokenUpdate) }
        for connection in hidden { #expect(!connection.allowsTokenUpdate) }
    }

    @Test("a failed status carries its plain reason, other states carry none")
    func statusCarriesReason() throws {
        let failed = try status(state: "fatal", errorCode: "missing_scope", neededScope: "connections:write", providedScope: "chat:write")
        #expect(failed.connection == .failed)
        #expect(failed.failure?.code == "missing_scope")
        #expect(failed.failure?.message.contains("connections:write") == true)
        #expect(try status(state: "connected", errorCode: "missing_scope").failure == nil)
        #expect(try status(state: "startup_failed").failure == nil)
    }

    struct ReasonCase: Sendable, CustomTestStringConvertible {
        let code: String?
        let needed: String?
        let provided: String?
        let expected: String?

        var testDescription: String { "\(code ?? "nil") needed=\(needed ?? "nil")" }
    }

    @Test("failure reason wording", arguments: [
        ReasonCase(
            code: "missing_scope", needed: "connections:write", provided: nil,
            expected: "The app token is missing the connections:write scope. Add it to your Slack app, then update the token."
        ),
        ReasonCase(
            code: "missing_scope", needed: "chat:write,im:history", provided: "channels:read",
            expected: "The bot token is missing the chat:write,im:history scope. It has: channels:read. Add it to your Slack app, then update the token."
        ),
        ReasonCase(
            code: "missing_scope", needed: nil, provided: nil,
            expected: "A Slack scope is missing. Add it to your Slack app, then update the token."
        ),
        ReasonCase(
            code: "missing_scope", needed: "bad scope <script>", provided: nil,
            expected: "A Slack scope is missing. Add it to your Slack app, then update the token."
        ),
        ReasonCase(
            code: "invalid_auth", needed: nil, provided: nil,
            expected: "Slack didn't accept a token. Check the bot token and the app token, then update them."
        ),
        ReasonCase(
            code: "token_revoked", needed: nil, provided: nil,
            expected: "A Slack token was revoked. Create a new token in your Slack app and update it."
        ),
        ReasonCase(
            code: "account_inactive", needed: nil, provided: nil,
            expected: "The Slack account behind these tokens is inactive. Use tokens from an active account."
        ),
        ReasonCase(
            code: "not_authed", needed: nil, provided: nil,
            expected: "Slack didn't receive a token. Update the tokens and try again."
        ),
        ReasonCase(code: "ratelimited", needed: nil, provided: nil, expected: "Slack said: ratelimited"),
        ReasonCase(code: "xoxb-1234 leak", needed: nil, provided: nil, expected: "Slack turned down the connection."),
        ReasonCase(code: nil, needed: "connections:write", provided: nil, expected: nil),
        ReasonCase(code: "  ", needed: nil, provided: nil, expected: nil),
    ])
    func reasonWording(_ item: ReasonCase) {
        let reason = SlackFailureReason(errorCode: item.code, neededScope: item.needed, providedScope: item.provided)
        #expect(reason?.message == item.expected)
    }

    @Test("only the starting state keeps polling")
    func settled() {
        #expect(SlackConnection.starting.isSettled == false)
        for settled in [SlackConnection.connected, .notConnected, .restartNeeded, .failed] { #expect(settled.isSettled) }
    }

    @Test("tokens need the xoxb and xapp prefixes and no whitespace")
    func tokenValidation() {
        #expect(SlackTokenUpdate(bot: "xoxb-123", app: "xapp-456")?.isComplete == true)
        #expect(SlackTokenUpdate(bot: " xoxb-123 \n", app: "xapp-456") != nil)
        #expect(SlackTokenUpdate(bot: "xoxp-123", app: "xapp-456") == nil)
        #expect(SlackTokenUpdate(bot: "xoxb-123", app: "xoxb-456") == nil)
        #expect(SlackTokenUpdate(bot: "xoxb-", app: "xapp-456") == nil)
        #expect(SlackTokenUpdate(bot: "xoxb-1 2", app: "xapp-456") == nil)
        #expect(SlackTokenUpdate(bot: "", app: "") == nil)
    }

    @Test("an update may carry just one valid token")
    func partialUpdates() {
        let botOnly = SlackTokenUpdate(bot: "xoxb-123", app: "  ")
        #expect(botOnly?.bot != nil && botOnly?.app == nil && botOnly?.isComplete == false)
        let appOnly = SlackTokenUpdate(bot: "", app: "xapp-456")
        #expect(appOnly?.bot == nil && appOnly?.app != nil)
        #expect(SlackTokenUpdate(bot: "nope", app: "") == nil)
        #expect(SlackTokenUpdate(bot: "", app: "xoxb-1") == nil)
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
        let tokens = try #require(SlackTokenUpdate(bot: "xoxb-secret-one", app: "xapp-secret-two"))
        let state = try await SlackService(gateway: bots.gateway).connect(profile: "a", tokens: tokens)
        #expect(state.connection == .restartNeeded)
        #expect(bots.calls.first?.params == ["bot_token": "xoxb-secret-one", "app_token": "xapp-secret-two", "profile": "a"])
    }

    @Test("an update sends only the token present and the secret appears only in the request")
    func partialConnect() async throws {
        let canary = "xoxb-CANARY-\(UUID().uuidString)"
        let bots = ScriptedBots()
        bots.script("messaging.slack.connect", [
            "profile": "a", "enabled": true, "configured": true, "gateway_running": true, "state": "retrying",
            "error_code": "missing_scope", "needed_scope": "connections:write",
        ])
        let update = try #require(SlackTokenUpdate(bot: canary, app: ""))
        let status = try await SlackService(gateway: bots.gateway).connect(profile: "a", tokens: update)
        #expect(bots.calls.first?.params == ["bot_token": .string(canary), "profile": "a"])
        #expect(status.connection == .failed)
        #expect(!"\(status)".contains(canary))
        #expect(!String(reflecting: update).contains(canary))

        let appBots = ScriptedBots()
        appBots.script("messaging.slack.connect", ["profile": "a", "enabled": true, "configured": true, "gateway_running": true, "state": "connected"])
        let appOnly = try #require(SlackTokenUpdate(bot: "", app: "xapp-only"))
        _ = try await SlackService(gateway: appBots.gateway).connect(profile: "a", tokens: appOnly)
        #expect(appBots.calls.first?.params == ["app_token": "xapp-only", "profile": "a"])
    }

    @Test("a refused connect never leaks the tokens into diagnostics or the error")
    func connectRefusal() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.slack.connect") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4101, message: "SLACK_BOT_TOKEN rejected"))
        }
        let tokens = try #require(SlackTokenUpdate(bot: "xoxb-secret-one", app: "xapp-secret-two"))
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
        let tokens = try #require(SlackTokenUpdate(bot: "xoxb-a", app: "xapp-b"))
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
        #expect(try await service.disconnect(profile: "a").connection == .notConnected)
        #expect(try await service.status(profile: "a").connection == .connected)
        #expect(bots.calls.map(\.params["profile"]) == ["a", "a"])
    }
}
