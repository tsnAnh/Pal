import Foundation
import PalConnect
import PalDevice
import PalProtocol
import Testing

@Suite("Secret string")
struct SecretStringTests {
    private func canary() -> String { "CANARY-\(UUID().uuidString)" }

    @Test func neverAppearsInAnyTextualOrReflectedForm() {
        let value = canary()
        let secret = SecretString(value)
        var dumped = ""
        dump(secret, to: &dumped)
        let texts = [
            "\(secret)", String(describing: secret), String(reflecting: secret), dumped,
            "\([secret])", "\(Optional(secret))", "\(["k": secret])", "\((secret, 1))",
        ]
        for text in texts { #expect(!text.contains(value)) }
        #expect(Mirror(reflecting: secret).children.isEmpty)
        #expect(secret.description == "<redacted>")
        #expect(secret.debugDescription == "<redacted>")
    }

    @Test func isNotCodable() {
        let secret = SecretString(canary())
        #expect((secret as Any) is Encodable == false)
        #expect((secret as Any) is Decodable == false)
    }

    @Test func revealIsExplicitAndEmptinessIsObservable() {
        let value = canary()
        #expect(SecretString(value).reveal() == value)
        #expect(SecretString("").isEmpty)
        #expect(!SecretString(value).isEmpty)
        #expect(SecretString(value) == SecretString(value))
    }

    @MainActor
    @Test func dialogsAndPhasesNeverCarryTheValue() async throws {
        let value = canary()
        let center = ServiceSignInCenter(call: { _, _ in ["outcome": "failed"] }, openBrowser: { _ in })
        center.receive(GatewayEvent(type: "auth.required", payload: [
            "request_id": "r1", "service": "linear", "service_name": "Linear", "bot": "atlas", "flow": "api_key",
        ]))
        await center.submitCredential(SecretString(value))
        let dialog = try #require(center.current)
        #expect(dialog.phase == .keyFailed("Couldn't save that. Check it and try again."))
        var dumped = ""
        dump(dialog, to: &dumped)
        for text in ["\(dialog)", String(reflecting: dialog), "\(dialog.phase)", dumped] { #expect(!text.contains(value)) }
        #expect((dialog as Any) is Encodable == false)
        #expect((dialog.phase as Any) is Encodable == false)
    }

    @Test func validatedConnectorsKeepHeaderValuesRedacted() throws {
        let value = canary()
        let draft = CustomConnectorDraft(
            name: "docs", url: "https://example.com/mcp", headers: [ConnectorHeader(key: "Authorization", value: value)]
        )
        let validated = try draft.validated()
        var dumped = ""
        dump(validated, to: &dumped)
        for text in ["\(validated)", String(reflecting: validated), dumped] { #expect(!text.contains(value)) }
    }
}
