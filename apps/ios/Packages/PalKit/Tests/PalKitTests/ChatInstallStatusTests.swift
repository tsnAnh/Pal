import Foundation
import PalBotProfile
import PalProtocol
import PalTransport
import Testing

@MainActor
struct ChatInstallStatusTests {
    @Test func everyFailureKindMapsToItsReason() {
        func rpc(_ code: Int, _ reason: String? = nil) -> GatewayTransportError {
            .rpc(RPCError(code: code, message: "x", data: reason.map { .object(["reason": .string($0)]) }))
        }
        #expect(ChatInstallClientError(GatewayTransportError.timedOut).reason == .timedOut)
        #expect(ChatInstallClientError(GatewayTransportError.closed(.normal)).reason == .offline)
        #expect(ChatInstallClientError(rpc(4403, "owner_only")).reason == .forbidden)
        #expect(ChatInstallClientError(rpc(4001, "permission_denied")).reason == .forbidden)
        #expect(ChatInstallClientError(rpc(4001, "profile_mismatch")).reason == .invalidParams)
        #expect(ChatInstallClientError(rpc(-32602)).reason == .invalidParams)
        #expect(ChatInstallClientError(rpc(5104, "provider_failed")).reason == .gateway)
        #expect(ChatInstallClientError(rpc(-32601)) == .unsupported)
        #expect(ChatInstallClientError(rpc(4501, "not_implemented")) == .unsupported)
        #expect(ChatInstallClientError(rpc(4409, "stale_revision")) == .staleRevision)
        #expect(ChatInstallClientError(CocoaError(.fileReadUnknown)).reason == .gateway)
    }

    @Test(arguments: [ChatFailureReason.forbidden, .invalidParams, .decode, .timedOut, .offline, .gateway])
    func unavailableScreenCarriesTheReasonAndRetryReloads(_ reason: ChatFailureReason) async throws {
        let client = FakeChatInstallClient([try chatProvider()], try chatState("not_started", 0))
        await client.failProviders(.failed(reason))
        let model = ChatInstallModel(botName: "pal", preferredProvider: "slack", client: client)
        await model.load()
        #expect(model.screen == .unavailable)
        #expect(model.loadFailure == reason)
        #expect(model.primaryAction == .reload)
        #expect(model.statusCode == reason.rawValue)
        #expect(model.isStatusScreen)
        await client.failProviders(.unsupported)
        await model.load()
        #expect(model.screen == .unsupported)
        #expect(model.loadFailure == nil)
        #expect(model.statusCode == ChatInstallModel.gatewayOutdatedCode)
        #expect(model.isStatusScreen)
    }

    @Test func aSetupErrorIsAStatusScreenWithItsCode() async throws {
        let failed = try chatState("error", 3, error: ["code": "credential_expired", "fix": "reenter_credential"])
        let model = ChatInstallModel(botName: "pal", preferredProvider: "slack", client: FakeChatInstallClient([try chatProvider()], failed))
        await model.load()
        #expect(model.isStatusScreen)
        #expect(model.statusCode == "credential_expired")
    }
}
