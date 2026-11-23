import PalBotProfile
import Testing

@Suite("Capability groups")
struct CapabilityGroupsTests {
    private let on = CapabilityRow(id: "web", label: "Web search", state: .on)
    private let limitedWithKey = CapabilityRow(id: "maps", label: "Maps", state: .on, reason: "Needs GOOGLE_MAPS_API_KEY.", keyName: "GOOGLE_MAPS_API_KEY")
    private let limitedWithoutKey = CapabilityRow(id: "voice", label: "Voice", state: .on, reason: "Runs slowly on this device.")
    private let offWithKey = CapabilityRow(id: "deep", label: "Deep search", state: .off, reason: "Needs a search key.", keyName: "EXA_API_KEY")
    private let offWithChoices = CapabilityRow(id: "speech", label: "Speech", state: .off, keyChoices: ["ELEVENLABS_API_KEY", "MISTRAL_API_KEY"])
    private let offWithoutKey = CapabilityRow(id: "browser", label: "Browser", state: .off, reason: "Pick a provider.", setting: "browser.cloud_provider")
    private let unavailable = CapabilityRow(id: "youtube", label: "YouTube", state: .unavailable, reason: "Not installed.", keyName: "YOUTUBE_API_KEY")

    private func ids(_ group: CapabilityGroup?) -> [String] { group?.rows.map(\.id) ?? [] }

    @Test("a limited or off row with a settable key needs a key")
    func needsKey() {
        #expect(limitedWithKey.groupKind == .needsKey)
        #expect(offWithKey.groupKind == .needsKey)
        #expect(offWithChoices.groupKind == .needsKey)
    }

    @Test("an on row, and a limited row with no key to set, sit under On")
    func onGroup() {
        #expect(on.groupKind == .on)
        #expect(limitedWithoutKey.groupKind == .on)
    }

    @Test("an off row without a key and an unavailable row sit under Off, even when a key name is sent")
    func offGroup() {
        #expect(offWithoutKey.groupKind == .off)
        #expect(unavailable.groupKind == .off)
    }

    @Test("groups come in order needs a key, on, off and keep the gateway order inside")
    func order() {
        let groups = [on, offWithoutKey, offWithKey, unavailable, limitedWithKey, offWithChoices, limitedWithoutKey].groupedByState
        #expect(groups.map(\.kind) == [.needsKey, .on, .off])
        #expect(ids(groups[0]) == ["deep", "maps", "speech"])
        #expect(ids(groups[1]) == ["web", "voice"])
        #expect(ids(groups[2]) == ["browser", "youtube"])
    }

    @Test("a group with no rows is not drawn")
    func emptyGroupsDropped() {
        #expect([on].groupedByState.map(\.kind) == [.on])
        #expect([offWithKey, limitedWithKey].groupedByState.map(\.kind) == [.needsKey])
        #expect([unavailable].groupedByState.map(\.kind) == [.off])
        #expect([CapabilityRow]().groupedByState.isEmpty)
    }

    @Test("every row lands in exactly one group")
    func partition() {
        let all = [on, limitedWithKey, limitedWithoutKey, offWithKey, offWithChoices, offWithoutKey, unavailable]
        let groups = all.groupedByState
        #expect(groups.flatMap(\.rows).count == all.count)
        #expect(Set(groups.flatMap(\.rows).map(\.id)) == Set(all.map(\.id)))
    }
}
