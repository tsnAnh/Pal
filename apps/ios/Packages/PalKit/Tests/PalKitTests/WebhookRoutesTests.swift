import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalTransport

private func routeJSON(_ name: String, publicURL: String? = nil, enabled: Bool = true) -> JSONValue {
    var object: [String: JSONValue] = [
        "name": .string(name), "profile": "default", "path": .string("/webhooks/\(name)"),
        "events": ["push", "pull_request"], "deliver": "log", "description": "GitHub events",
        "created_at": "2026-11-01T10:00:00Z", "enabled": .bool(enabled),
    ]
    object["public_url"] = publicURL.map { .string($0) } ?? .null
    return .object(object)
}

private func listJSON(base: String? = "https://pal.example.net", setting: String = "PAL_PUBLIC_URL", routes: [JSONValue] = []) -> JSONValue {
    ["enabled": true, "public_base_url": base.map { .string($0) } ?? .null, "public_url_setting": .string(setting), "routes": .array(routes)]
}

private func probeJSON(code: String, message: String = "msg", local: Int? = 401, publicStatus: Int? = 502) -> JSONValue {
    [
        "local": ["status": local.map { .int($0) } ?? .null, "ms": 12, "error": .null],
        "public": ["status": publicStatus.map { .int($0) } ?? .null, "ms": 340, "error": .null],
        "diagnosis": ["code": .string(code), "message": .string(message)],
        "tunnel": ["resolves": true, "tls_expires_at": "2027-01-01T00:00:00Z"],
    ]
}

@MainActor
private func model(_ bots: ScriptedBots) -> WebhookRoutesModel {
    WebhookRoutesModel(client: WebhookRoutesClient(gateway: bots.gateway), surfaces: scratchSurfaces())
}

private let methodNotFound = GatewayTransportError.rpc(RPCError(code: -32601, message: "method not found"))
private let notOwner = GatewayTransportError.rpc(RPCError(code: 4403, message: "forbidden"))

@Suite("Public access")
@MainActor
struct WebhookRoutesTests {
    @Test("the route list parses the base URL, setting name and each route")
    func parseList() async {
        let bots = ScriptedBots()
        bots.script(
            "webhook.routes.list",
            listJSON(routes: [routeJSON("github", publicURL: "https://pal.example.net/webhooks/github"), routeJSON("off", enabled: false)]))
        let routes = model(bots)
        await routes.refresh()
        #expect(routes.list?.publicAddressText == "https://pal.example.net")
        #expect(routes.list?.missingSettingHint == nil)
        #expect(routes.routes.map(\.name) == ["github", "off"])
        #expect(routes.routes[0].publicURL?.absoluteString == "https://pal.example.net/webhooks/github")
        #expect(routes.routes[0].events == ["push", "pull_request"])
        #expect(routes.routes[1].publicURL == nil)
        #expect(!routes.routes[1].isEnabled)
    }

    @Test("a missing base URL reads Not configured and names the setting")
    func notConfigured() async {
        let bots = ScriptedBots()
        bots.script("webhook.routes.list", listJSON(base: nil, setting: "PAL_PUBLIC_URL"))
        let routes = model(bots)
        await routes.refresh()
        #expect(routes.list?.publicAddressText == "Not configured")
        #expect(routes.list?.missingSettingHint == "Set PAL_PUBLIC_URL on the computer that runs Pal.")
    }

    @Test("every diagnosis code maps to a headline and severity, unknown codes fall back")
    func diagnosisTable() {
        let expected: [(String, WebhookSeverity)] = [
            ("ok", .good), ("route_not_loaded", .failure), ("route_disabled", .warning), ("local_unreachable", .failure),
            ("public_unconfigured", .warning), ("public_not_reaching_gateway", .failure), ("public_wrong_target", .failure),
            ("public_timeout", .failure), ("public_tls", .failure), ("public_dns", .failure), ("public_unreachable", .failure),
            ("probe_skipped", .neutral),
        ]
        var headlines = Set<String>()
        for (code, severity) in expected {
            let diagnosis = WebhookDiagnosis(["code": .string(code), "message": "m"])
            #expect(diagnosis.isKnown, "\(code)")
            #expect(diagnosis.severity == severity, "\(code)")
            headlines.insert(diagnosis.headline)
        }
        #expect(headlines.count == expected.count)
        let odd = WebhookDiagnosis(["code": "from_the_future", "message": "Something new broke."])
        #expect(!odd.isKnown)
        #expect(odd.headline == "Check finished")
        #expect(odd.severity == .neutral)
        #expect(odd.message == "Something new broke.")
        #expect(WebhookDiagnosis(nil).code.isEmpty)
    }

    @Test("a probe shows both hops, so a 502 public answer beside a 401 local answer is visible")
    func probeShowsBothHops() async {
        let bots = ScriptedBots()
        bots.script("webhook.routes.probe", probeJSON(code: "public_not_reaching_gateway", message: "The tunnel answers 502."))
        let routes = model(bots)
        await routes.probe("github")
        guard case .finished(let result)? = routes.probes["github"] else { Issue.record("no result"); return }
        #expect(result.local.summary == "Answered 401 in 12 ms")
        #expect(result.publicHop.summary == "Answered 502 in 340 ms")
        #expect(result.diagnosis.severity == .failure)
        #expect(result.diagnosis.message == "The tunnel answers 502.")
        #expect(result.resolves == true)
        #expect(bots.calls(to: "webhook.routes.probe").first?.params == ["name": "github"])
        #expect(WebhookHop(["status": .null, "ms": .null, "error": "timed out"]).summary == "No answer: timed out")
        #expect(WebhookHop(nil).summary == "Not checked")
    }

    @Test("a generated secret is held once and cleared, never part of the list")
    func generatedSecretIsTransient() async {
        let bots = ScriptedBots()
        bots.script("webhook.routes.list", listJSON())
        bots.script("webhook.routes.add") { _ in ["route": routeJSON("github"), "secret": "s3cr3t-value"] }
        bots.script("webhook.routes.list", listJSON(routes: [routeJSON("github")]))
        let routes = model(bots)
        await routes.refresh()
        let ok = await routes.add(WebhookRouteDraft(name: " github ", eventsText: "push, pull_request"), typedSecret: nil)
        #expect(ok)
        #expect(routes.issuedSecret == "s3cr3t-value")
        #expect(routes.issuedRouteName == "github")
        let call = bots.calls(to: "webhook.routes.add").first?.params
        #expect(call?["generate_secret"] == .bool(true))
        #expect(call?["secret"] == nil)
        #expect(call?["name"] == "github")
        #expect(call?["events"] == ["push", "pull_request"])
        #expect(!"\(routes.list as Any)".contains("s3cr3t-value"))
        routes.clearIssuedSecret()
        #expect(routes.issuedSecret == nil)
        await routes.refresh()
        #expect(routes.issuedSecret == nil)
        #expect(!"\(routes.list as Any)".contains("s3cr3t-value"))
    }

    @Test("a typed secret is sent as secret and never kept")
    func typedSecretIsNotRetained() async {
        let bots = ScriptedBots()
        bots.script("webhook.routes.list", listJSON())
        bots.script("webhook.routes.add") { _ in ["route": routeJSON("github"), "secret": .null] }
        let routes = model(bots)
        await routes.refresh()
        let ok = await routes.add(WebhookRouteDraft(name: "github"), typedSecret: "  typed-secret  ")
        #expect(ok)
        let call = bots.calls(to: "webhook.routes.add").first?.params
        #expect(call?["secret"] == "typed-secret")
        #expect(call?["generate_secret"] == nil)
        #expect(call?["events"] == nil)
        #expect(routes.issuedSecret == nil)
    }

    @Test("an invalid draft or blank typed secret never reaches the gateway")
    func addValidation() async {
        let bots = ScriptedBots()
        let routes = model(bots)
        #expect(await routes.add(WebhookRouteDraft(name: ""), typedSecret: nil) == false)
        #expect(await routes.add(WebhookRouteDraft(name: "has space"), typedSecret: nil) == false)
        #expect(await routes.add(WebhookRouteDraft(name: "ok"), typedSecret: "   ") == false)
        #expect(bots.calls(to: "webhook.routes.add").isEmpty)
        #expect(routes.addState == .failed(WebhookRoutesModel.addFailure))
        routes.resetAdd()
        #expect(routes.addState == .idle)
    }

    @Test("remove sends the name and refreshes")
    func remove() async {
        let bots = ScriptedBots()
        bots.script("webhook.routes.list", listJSON(routes: [routeJSON("github")]))
        bots.script("webhook.routes.remove", ["ok": true])
        bots.script("webhook.routes.list", listJSON())
        let routes = model(bots)
        await routes.refresh()
        await routes.remove("github")
        #expect(bots.calls(to: "webhook.routes.remove").first?.params == ["name": "github"])
        #expect(routes.routes.isEmpty)
    }

    @Test("method-not-found is unsupported and 4403 is not-owner")
    func failures() async {
        let old = ScriptedBots()
        old.script("webhook.routes.list") { _ in throw methodNotFound }
        let oldModel = model(old)
        await oldModel.refresh()
        #expect(oldModel.phase == .unsupported)
        #expect(!oldModel.canManage)
        let guest = ScriptedBots()
        guest.script("webhook.routes.list") { _ in throw notOwner }
        let guestModel = model(guest)
        await guestModel.refresh()
        #expect(guestModel.phase == .notOwner)
        #expect(guestModel.footnote == "Only the owner of this computer can manage public access.")
    }

    @Test("a failing refresh keeps the last good list")
    func keepsLastGood() async {
        let bots = ScriptedBots()
        bots.script("webhook.routes.list", listJSON(routes: [routeJSON("github")]))
        bots.script("webhook.routes.list") { _ in throw ScriptedBots.ScriptError.unscripted("x") }
        let routes = model(bots)
        await routes.refresh()
        await routes.refresh()
        #expect(routes.routes.map(\.name) == ["github"])
    }
}
