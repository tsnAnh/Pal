import Foundation
import HermesBotProfile
import HermesProtocol
import HermesTransport
import Testing

@Suite("Telegram connection")
struct TelegramTests {
    private func status(
        configured: Bool = true,
        state: String? = nil,
        restartStarted: Bool? = nil,
        restartBusy: Bool? = nil,
        restartError: String? = nil,
        errorCode: String? = nil,
        allowedUsersSet: Bool? = nil
    ) throws -> TelegramStatus {
        var object: [String: JSONValue] = ["enabled": .bool(configured), "configured": .bool(configured), "gateway_running": true]
        if let state { object["state"] = .string(state) }
        if let restartStarted { object["restart_started"] = .bool(restartStarted) }
        if let restartBusy { object["restart_busy"] = .bool(restartBusy) }
        if let restartError { object["restart_error"] = .string(restartError) }
        if let errorCode { object["error_code"] = .string(errorCode) }
        if let allowedUsersSet { object["allowed_users_set"] = .bool(allowedUsersSet) }
        return TelegramStatus(try JSONValue.object(object).decoded(as: TelegramStatusWire.self))
    }

    private func connection(_ state: String?, errorCode: String? = nil, configured: Bool = true) throws -> TelegramConnection {
        try status(configured: configured, state: state, errorCode: errorCode).connection
    }

    private static let token = "123456789:AAH-secret_token_value_0123456789abc"

    @Test("status maps to connected, not connected, restart needed, starting and failed")
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

    @Test("fatal and retrying with an error code fail, without one they keep starting")
    func failureStates() throws {
        for state in ["fatal", "retrying", "startup_failed"] {
            #expect(try connection(state, errorCode: "telegram_auth_error") == .failed, "\(state)")
        }
        #expect(try connection("fatal") == .starting)
        #expect(try connection("retrying", errorCode: "") == .starting)
        #expect(try connection("connected", errorCode: "telegram_auth_error") == .connected)
    }

    @Test("token update is offered only for failed and connected")
    func updateRule() {
        for connection in [TelegramConnection.failed, .connected] { #expect(connection.allowsTokenUpdate) }
        for connection in [TelegramConnection.notConnected, .starting, .restartNeeded] { #expect(!connection.allowsTokenUpdate) }
        #expect(TelegramConnection.starting.isSettled == false)
    }

    struct ReasonCase: Sendable, CustomTestStringConvertible {
        let code: String?
        let expected: String?

        var testDescription: String { code ?? "nil" }
    }

    @Test("failure reason wording", arguments: [
        ReasonCase(code: "telegram_auth_error", expected: "Telegram doesn't accept this token. It may be wrong or revoked. Create a new one with @BotFather and update it."),
        ReasonCase(code: "telegram_network_error", expected: TelegramFailureReason.network),
        ReasonCase(code: "telegram_connect_error", expected: TelegramFailureReason.network),
        ReasonCase(code: "telegram_polling_conflict", expected: TelegramFailureReason.conflict),
        ReasonCase(code: "123456:SECRET leak", expected: "Telegram turned down the connection."),
        ReasonCase(code: "brand_new_code", expected: "Telegram turned down the connection."),
        ReasonCase(code: nil, expected: nil),
        ReasonCase(code: "  ", expected: nil),
    ])
    func reasonWording(_ item: ReasonCase) {
        #expect(TelegramFailureReason(errorCode: item.code)?.message == item.expected)
    }

    @Test("a failed status carries its reason, other states carry none")
    func statusCarriesReason() throws {
        let failed = try status(state: "fatal", errorCode: "telegram_polling_conflict")
        #expect(failed.connection == .failed)
        #expect(failed.failure?.code == "telegram_polling_conflict")
        #expect(try status(state: "connected", errorCode: "telegram_auth_error").failure == nil)
        #expect(try status(state: "startup_failed").failure == nil)
    }

    @Test("allowed users flag defaults to set when the gateway does not say")
    func allowedUsers() throws {
        #expect(try status(state: "connected", allowedUsersSet: false).allowedUsersSet == false)
        #expect(try status(state: "connected", allowedUsersSet: true).allowedUsersSet)
        #expect(try status(state: "connected").allowedUsersSet)
    }

    private static func run(_ count: Int) -> String {
        String(repeating: "a", count: count)
    }

    private static let shapeCases: [(String, Bool)] = {
        var cases: [(String, Bool)] = []
        cases.append((token, true))
        cases.append(("  \(token)\n", true))
        cases.append(("1:" + run(30), true))
        cases.append(("1:" + run(29), false))
        cases.append((":" + run(30), false))
        cases.append(("12a:" + run(30), false))
        cases.append(("12:\(run(15)) \(run(15))", false))
        cases.append(("12:\(run(29))!", false))
        cases.append(("12:\(run(20)):\(run(20))", false))
        cases.append(("xoxb-123", false))
        cases.append(("", false))
        return cases
    }()

    @Test("token must have the BotFather shape after trimming", arguments: TelegramTests.shapeCases)
    func tokenValidation(_ item: (String, Bool)) {
        #expect((TelegramTokenUpdate(item.0) != nil) == item.1)
    }

    @Test("connect sends only the bot token to the named bot and reports the state")
    func connect() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.telegram.connect", [
            "profile": "a", "enabled": true, "configured": true, "gateway_running": true, "state": "pending_restart",
            "bot_token_set": true, "allowed_users_set": false, "hot_served": false, "restart_started": false, "restart_busy": true,
        ])
        let update = try #require(TelegramTokenUpdate(Self.token))
        let result = try await TelegramService(gateway: bots.gateway).connect(profile: "a", token: update)
        #expect(result.connection == .restartNeeded)
        #expect(result.allowedUsersSet == false)
        #expect(bots.calls.first?.params == ["bot_token": .string(Self.token), "profile": "a"])
        #expect(!"\(result)".contains(Self.token))
        #expect(!String(reflecting: update).contains(Self.token))
        #expect(!String(describing: update).contains(Self.token))
    }

    @Test("a rejected token and an unreachable Telegram are distinct and never leak the token")
    func connectRefusals() async throws {
        let update = try #require(TelegramTokenUpdate(Self.token))
        let cases: [(Int, BotsError)] = [
            (4101, .rejected(reason: TelegramService.invalidTokenReason)),
            (5103, .rejected(reason: TelegramService.networkReason)),
            (5102, .rejected(reason: nil)),
        ]
        for (code, expected) in cases {
            let bots = ScriptedBots()
            bots.script("messaging.telegram.connect") { _ in
                throw GatewayTransportError.rpc(RPCError(code: code, message: "TELEGRAM_BOT_TOKEN refused"))
            }
            do {
                _ = try await TelegramService(gateway: bots.gateway).connect(profile: "a", token: update)
                Issue.record("expected a refusal for \(code)")
            } catch let error as BotsError {
                #expect(error == expected, "\(code)")
                #expect(!String(describing: error).contains("AAH"))
            }
        }
        #expect(TelegramService.invalidTokenReason != TelegramService.networkReason)
    }

    @Test("disconnect and status address the named bot")
    func disconnect() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.telegram.disconnect", [
            "profile": "a", "enabled": false, "configured": false, "gateway_running": true, "state": "not_configured",
            "bot_token_set": false, "allowed_users_set": true, "hot_served": true, "restart_started": false,
        ])
        bots.script("messaging.telegram.status", [
            "profile": "a", "enabled": true, "configured": true, "gateway_running": true, "state": "connected",
            "bot_token_set": true, "allowed_users_set": true,
        ])
        let service = TelegramService(gateway: bots.gateway)
        #expect(try await service.disconnect(profile: "a").connection == .notConnected)
        #expect(try await service.status(profile: "a").connection == .connected)
        #expect(bots.calls.map(\.params["profile"]) == ["a", "a"])
        #expect(bots.calls.allSatisfy { $0.params["bot_token"] == nil })
    }
}
