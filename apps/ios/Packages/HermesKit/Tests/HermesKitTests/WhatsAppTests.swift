import Foundation
import HermesBotProfile
import HermesProtocol
import HermesTransport
import Testing

private let canary = "CANARY-NOT-A-REAL-QR-0000"

private func pairing(_ status: String, qr: String? = nil, id: String = "p1", extra: [String: JSONValue] = [:]) throws -> WhatsAppPairingWire {
    var object: [String: JSONValue] = [
        "pairing_id": .string(id), "status": .string(status), "expires_at": "2026-01-01T00:00:00Z",
        "mode": "self-chat", "allowed_users": "+84901234567",
    ]
    if let qr { object["qr_payload"] = .string(qr) }
    object.merge(extra) { $1 }
    return try JSONValue.object(object).decoded(as: WhatsAppPairingWire.self)
}

private func dumped(_ value: Any) -> String {
    var text = ""
    dump(value, to: &text)
    return text
}

@Suite("WhatsApp wire")
struct WhatsAppWireTests {
    @Test("status decodes mode, allowed numbers, account and the merged reload fields")
    func status() throws {
        let wire = try JSONValue.object([
            "profile": "a", "enabled": true, "paired": true, "mode": "bot", "allowed_users": "+1415,+8490",
            "account_name": "An", "account_phone": "+84901234567", "gateway_running": true, "state": "connected",
            "error_code": "x", "error_message": "y", "ok": true, "hot_served": false, "restart_started": true,
            "restart_busy": false, "restart_error": "boom",
        ]).decoded(as: WhatsAppStatusWire.self)
        let status = WhatsAppStatus(wire)
        #expect(status.isEnabled && status.isPaired)
        #expect(status.mode == .bot)
        #expect(status.allowedUsers == "+1415,+8490")
        #expect(status.account == WhatsAppAccount(name: "An", phone: "+84901234567"))
        #expect(status.reload.restartStarted)
        #expect(status.reload.restartFailed)
        #expect(status.reload.needsAttention)
    }

    @Test("status tolerates an empty mode and missing optional fields")
    func sparseStatus() throws {
        let wire = try JSONValue.object(["profile": "a", "enabled": false, "paired": false, "mode": "", "allowed_users": ""]).decoded(as: WhatsAppStatusWire.self)
        let status = WhatsAppStatus(wire)
        #expect(status.mode == nil)
        #expect(status.account.isEmpty)
        #expect(!status.reload.needsAttention)
    }

    @Test("pairing decodes every status and field")
    func pairingFields() throws {
        for status in ["starting", "waiting", "connected", "error", "expired", "cancelled"] {
            #expect(try pairing(status).status == status)
        }
        let full = try pairing("connected", qr: canary, extra: ["account_name": "An", "account_phone": "+8490", "error": "nope"])
        #expect(full.pairingID == "p1")
        #expect(full.qrPayload?.value == canary)
        #expect(full.expiresAt == "2026-01-01T00:00:00Z")
        #expect(full.mode == "self-chat")
        #expect(full.allowedUsers == "+84901234567")
        #expect(full.accountName == "An" && full.accountPhone == "+8490" && full.error == "nope")
    }

    @Test("reload decodes")
    func reload() throws {
        let wire = try JSONValue.object(["ok": true, "hot_served": true, "restart_started": false, "restart_busy": true, "restart_error": "e"]).decoded(as: WhatsAppReloadWire.self)
        #expect(wire == WhatsAppReloadWire(ok: true, hotServed: true, restartStarted: false, restartBusy: true, restartError: "e"))
        #expect(WhatsAppReload(wire).needsAttention)
    }

    @Test("allowed numbers are normalized and validated")
    func allowedUsers() {
        #expect(WhatsAppAllowedUsers.normalized("+84901234567, 14155550123\n+4420") == nil)
        #expect(WhatsAppAllowedUsers.normalized("+84901234567, 14155550123") == "+84901234567,14155550123")
        #expect(WhatsAppAllowedUsers.normalized("") == "")
        #expect(WhatsAppAllowedUsers.normalized("abc") == nil)
        #expect(WhatsAppAllowedUsers.normalized("+8490-123") == nil)
    }
}

@Suite("WhatsApp pairing state")
struct WhatsAppPairingStateTests {
    private func showing() throws -> WhatsAppPairingState {
        WhatsAppPairingMachine.reduce(.starting(pairingID: nil), .polled(try pairing("waiting", qr: canary)))
    }

    @Test("start, waiting with a code, waiting without one and connected")
    func happyPath() throws {
        var state = WhatsAppPairingMachine.reduce(.idle, .startRequested)
        #expect(state == .starting(pairingID: nil))
        state = WhatsAppPairingMachine.reduce(state, .polled(try pairing("starting")))
        #expect(state == .starting(pairingID: "p1"))
        state = WhatsAppPairingMachine.reduce(state, .polled(try pairing("waiting", qr: canary)))
        #expect(state.qr?.value == canary)
        #expect(state.pairingID == "p1")
        state = WhatsAppPairingMachine.reduce(state, .polled(try pairing("waiting")))
        #expect(state == .connecting(pairingID: "p1"))
        state = WhatsAppPairingMachine.reduce(state, .polled(try pairing("connected", extra: ["account_name": "An", "account_phone": "+8490"])))
        #expect(state == .connected(pairingID: "p1", account: WhatsAppAccount(name: "An", phone: "+8490")))
    }

    @Test("the code is cleared on every terminal status")
    func terminalClearsQR() throws {
        let cases: [(String, WhatsAppPairingState)] = [
            ("connected", .connected(pairingID: "p1", account: WhatsAppAccount(name: nil, phone: nil))),
            ("error", .failed(.pairingFailed)),
            ("expired", .expired),
            ("cancelled", .idle),
            ("something_new", .failed(.pairingFailed)),
        ]
        for (status, expected) in cases {
            let state = WhatsAppPairingMachine.reduce(try showing(), .polled(try pairing(status, qr: canary)))
            #expect(state == expected)
            #expect(state.qr == nil)
            #expect(!dumped(state).contains(canary))
        }
    }

    @Test("cancel, a missing pairing, a failed request and leaving the foreground clear the code")
    func eventsClearQR() throws {
        #expect(WhatsAppPairingMachine.reduce(try showing(), .cancelled) == .idle)
        #expect(WhatsAppPairingMachine.reduce(try showing(), .leftForeground) == .idle)
        #expect(WhatsAppPairingMachine.reduce(try showing(), .pairingGone) == .expired)
        #expect(WhatsAppPairingMachine.reduce(try showing(), .requestFailed(.unavailable)) == .failed(.unavailable))
        for event in [WhatsAppPairingEvent.cancelled, .leftForeground, .pairingGone, .requestFailed(.unavailable)] {
            #expect(WhatsAppPairingMachine.reduce(try showing(), event).qr == nil)
        }
    }

    @Test("backgrounding keeps a finished outcome and ignores late polls")
    func settledStatesStay() throws {
        let connected = WhatsAppPairingState.connected(pairingID: "p1", account: WhatsAppAccount(name: "An", phone: nil))
        #expect(WhatsAppPairingMachine.reduce(connected, .leftForeground) == connected)
        #expect(WhatsAppPairingMachine.reduce(.expired, .leftForeground) == .expired)
        #expect(WhatsAppPairingMachine.reduce(.expired, .polled(try pairing("waiting", qr: canary))) == .expired)
        #expect(WhatsAppPairingMachine.reduce(.idle, .polled(try pairing("waiting", qr: canary))) == .idle)
        #expect(WhatsAppPairingMachine.reduce(.idle, .pairingGone) == .idle)
    }

    @Test("only starting, showing and connecting are active")
    func activity() throws {
        #expect(WhatsAppPairingState.starting(pairingID: nil).isActive)
        #expect(try showing().isActive)
        #expect(WhatsAppPairingState.connecting(pairingID: "p1").isActive)
        for settled in [WhatsAppPairingState.idle, .expired, .failed(.unavailable), .connected(pairingID: "p1", account: WhatsAppAccount(name: nil, phone: nil))] {
            #expect(!settled.isActive)
        }
    }
}

@Suite("WhatsApp QR secrecy")
struct WhatsAppQRSecrecyTests {
    @Test("no description, debug description, interpolation or dump of a pairing or state shows the code")
    func redaction() throws {
        let wire = try pairing("waiting", qr: canary)
        let state = WhatsAppPairingMachine.reduce(.starting(pairingID: nil), .polled(wire))
        #expect(state.qr?.value == canary)
        let rendered = [
            String(describing: wire), String(reflecting: wire), "\(wire)", dumped(wire),
            String(describing: state), String(reflecting: state), "\(state)", dumped(state),
            String(describing: wire.qrPayload as Any), dumped(wire.qrPayload as Any),
            String(describing: WhatsAppPairingEvent.polled(wire)),
        ]
        for text in rendered { #expect(!text.contains(canary)) }
        #expect(String(describing: wire).contains("<redacted>"))
    }
}

@Suite("WhatsApp service")
struct WhatsAppServiceTests {
    private func statusObject(paired: Bool = true) -> JSONValue {
        ["profile": "a", "enabled": true, "paired": .bool(paired), "mode": "bot", "allowed_users": "+8490", "gateway_running": true]
    }

    @Test("every call addresses the named bot with the contract parameters")
    func calls() async throws {
        let bots = ScriptedBots()
        bots.script("messaging.whatsapp.status", statusObject())
        bots.script("messaging.whatsapp.pair.start", ["pairing_id": "p1", "status": "waiting", "qr_payload": .string(canary), "expires_at": "x", "mode": "bot", "allowed_users": "+8490"])
        bots.script("messaging.whatsapp.pair.status", ["pairing_id": "p1", "status": "connected", "expires_at": "x", "mode": "bot", "allowed_users": "+8490"])
        bots.script("messaging.whatsapp.pair.cancel", ["ok": true])
        bots.script("messaging.whatsapp.pair.apply", ["ok": true, "hot_served": true, "restart_started": false])
        bots.script("messaging.whatsapp.unpair", ["profile": "a", "enabled": false, "paired": false, "mode": "", "allowed_users": "", "restart_started": false])
        bots.script("messaging.whatsapp.configure", statusObject())
        let service = WhatsAppService(gateway: bots.gateway)

        #expect(try await service.status(profile: "a").isPaired)
        let started = try await service.startPairing(profile: "a", mode: .bot, allowedUsers: "+8490", resetSession: true)
        #expect(started.qrPayload?.value == canary)
        #expect(try await service.pairingStatus(profile: "a", pairingID: "p1").status == "connected")
        try await service.cancelPairing(profile: "a", pairingID: "p1")
        let reload = try await service.applyPairing(profile: "a", pairingID: "p1", mode: .selfChat, allowedUsers: "+8490")
        #expect(!reload.needsAttention)
        #expect(try await service.unpair(profile: "a").isPaired == false)
        #expect(try await service.configure(profile: "a", mode: .bot, allowedUsers: "+8490").mode == .bot)

        #expect(bots.calls.map(\.method) == [
            "messaging.whatsapp.status", "messaging.whatsapp.pair.start", "messaging.whatsapp.pair.status",
            "messaging.whatsapp.pair.cancel", "messaging.whatsapp.pair.apply", "messaging.whatsapp.unpair", "messaging.whatsapp.configure",
        ])
        #expect(bots.calls(to: "messaging.whatsapp.pair.start").first?.params == ["profile": "a", "mode": "bot", "allowed_users": "+8490", "reset_session": true])
        #expect(bots.calls(to: "messaging.whatsapp.pair.status").first?.params == ["profile": "a", "pairing_id": "p1"])
        #expect(bots.calls(to: "messaging.whatsapp.pair.apply").first?.params == ["profile": "a", "pairing_id": "p1", "mode": "self-chat", "allowed_users": "+8490"])
        #expect(bots.calls(to: "messaging.whatsapp.configure").first?.params == ["profile": "a", "mode": "bot", "allowed_users": "+8490"])
    }

    private func failure(code: Int, method: String = "messaging.whatsapp.pair.status") async -> (any Error)? {
        let bots = ScriptedBots()
        bots.script(method) { _ in throw GatewayTransportError.rpc(RPCError(code: code, message: "internal detail")) }
        do {
            _ = try await WhatsAppService(gateway: bots.gateway).pairingStatus(profile: "a", pairingID: "p1")
            return nil
        } catch {
            return error
        }
    }

    @Test("4113 means the pairing is gone and ends as expired")
    func notFound() async throws {
        let error = try #require(await failure(code: 4113))
        #expect(error as? BotsError == .notFound)
        let state = WhatsAppPairingMachine.reduce(.connecting(pairingID: "p1"), .pairingGone)
        #expect(state == .expired)
    }

    @Test("4119 is a conflict shown as another pairing in progress")
    func anotherPairing() async throws {
        let error = try #require(await failure(code: 4119, method: "messaging.whatsapp.pair.status"))
        #expect(error as? BotsError == .conflict)
        #expect(WhatsAppFailure(error) == .anotherPairingActive)
        let state = WhatsAppPairingMachine.reduce(.starting(pairingID: nil), .requestFailed(WhatsAppFailure(error)))
        #expect(state == .failed(.anotherPairingActive))
    }

    @Test("4111 is invalid settings, 5112 a plain failure, anything else unavailable")
    func otherCodes() async throws {
        #expect(WhatsAppFailure(try #require(await failure(code: 4111))) == .invalidSettings)
        #expect(WhatsAppFailure(try #require(await failure(code: 5112))) == .pairingFailed)
        #expect(WhatsAppFailure(GatewayTransportError.timedOut) == .unavailable)
    }
}
