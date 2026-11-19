import PalRoster
import Testing

@Suite("Create bot gate")
struct CreateBotGateTests {
    private func gate(_ name: String, refused: Bool = false, creating: Bool = false) -> CreateBotGate {
        CreateBotGate(identity: BotIdentity(entered: name), nameRefused: refused, isCreating: creating)
    }

    @Test func anEmptyNameNeedsAName() {
        #expect(gate("") == .needsName)
        #expect(gate("   ") == .needsName)
        #expect(!gate("").canCreate)
    }

    @Test func aNameTheAppCannotUseAsksForAnotherOne() {
        #expect(gate("default") == .pickAnotherName)
        #expect(!gate("default").canCreate)
    }

    @Test func aNameTheGatewayRefusedAsksForAnotherOne() {
        #expect(gate("Scout", refused: true) == .pickAnotherName)
        #expect(!gate("Scout", refused: true).canCreate)
    }

    @Test func aValidNameIsReady() {
        #expect(gate("Scout") == .ready)
        #expect(gate("Scout").canCreate)
    }

    @Test func creatingBeatsEveryOtherState() {
        #expect(gate("Scout", creating: true) == .creating)
        #expect(gate("", creating: true) == .creating)
        #expect(!gate("Scout", creating: true).canCreate)
    }
}
