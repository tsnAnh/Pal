import Foundation
import PalProtocol
import Testing

@Suite("Chat provider wire")
struct ChatProviderWireTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/chat-provider/wire.json")

    struct Shapes: Decodable {
        var ChatProviderListResult: PalProtocol.ChatProviderListResult
        var ChatInstallStatusResult: PalProtocol.ChatInstallStatusResult
        var ChatSpacesListResult: PalProtocol.ChatSpacesListResult
        var ChatSpaceJoinResult: PalProtocol.ChatSpaceJoinResult
        var ChatBindingListResult: PalProtocol.ChatBindingListResult
        var ChatInstallChangedPayload: PalProtocol.ChatInstallChangedPayload
        var ChatIdentityUpdateResult: PalProtocol.ChatIdentityUpdateResult
        var IdentityProjection: ChatIdentityProjectionWire
    }

    @Test func decodesPythonFixturesForBothProviders() throws {
        let data = try Data(contentsOf: Self.fixture)
        let shapes = try JSONDecoder().decode([String: Shapes].self, from: data)
        #expect(Set(shapes.keys) == ["fake-credential", "fake-authorize"])
        for (provider, shape) in shapes {
            #expect(shape.ChatInstallStatusResult.state.step == .ready, "\(provider)")
            #expect(shape.ChatInstallStatusResult.installation?.status == .active)
            #expect(shape.ChatProviderListResult.providers.first?.providerId == provider)
            #expect(shape.ChatSpaceJoinResult.outcome == .needsInvite)
            #expect(shape.ChatInstallChangedPayload.state == shape.ChatInstallStatusResult.state)
            #expect(shape.ChatIdentityUpdateResult.outcome == .needsManualAvatar)
            #expect(shape.ChatIdentityUpdateResult.nextAction.actionId == "set_icon")
        }
        #expect(shapes["fake-credential"]?.ChatInstallStatusResult.state.appId != nil)
        #expect(shapes["fake-authorize"]?.ChatInstallStatusResult.state.appId == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("fake-token-do-not-use"))
    }

    @Test func unknownEnumValuesDecodeToUnknown() throws {
        let step = try JSONDecoder().decode([ChatSetupStep].self, from: Data(#"["later_step"]"#.utf8))
        #expect(step == [.unknown])
    }
}
