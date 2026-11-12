import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalRoster
@testable import PalTransport

private func refusal(_ code: Int) -> GatewayTransportError {
    .rpc(RPCError(code: code, message: "refused"))
}

@Suite("Bot description and personality")
struct BotPersonaTests {
    private let original = BotPersona(description: "Plans trips", soul: "# Atlas\nCalm and direct.")

    private func client(_ bots: ScriptedBots) -> BotPersonaClient {
        BotPersonaClient(gateway: bots.gateway, profile: "atlas")
    }

    @Test("load reads the description and personality for this bot")
    func loads() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.describe", ["name": "atlas", "description": "Plans trips", "soul": "# Atlas"])
        let persona = try await client(bots).load()
        #expect(persona == BotPersona(description: "Plans trips", soul: "# Atlas"))
        #expect(bots.calls(to: "profiles.describe").first?.params == ["name": "atlas"])
    }

    @Test("a failed load surfaces an error instead of empty fields")
    func loadFails() async {
        let bots = ScriptedBots()
        bots.script("profiles.describe") { _ in throw refusal(5000) }
        await #expect(throws: BotsError.self) { try await client(bots).load() }
    }

    @Test("only fields that differ count as changed, and spacing around the description is ignored")
    func changedFields() {
        #expect(BotPersonaEdit(description: "  Plans trips ", soul: original.soul).changedFields(from: original).isEmpty)
        #expect(BotPersonaEdit(description: "Plans trips", soul: "new").changedFields(from: original) == [.soul])
        #expect(BotPersonaEdit(description: "Cooks", soul: original.soul).changedFields(from: original) == [.description])
    }

    @Test("limits mirror the gateway: 280 for the description, 20,000 and not blank for the personality")
    func limits() {
        let long = String(repeating: "a", count: BotPersona.maximumDescriptionLength + 1)
        #expect(!BotPersonaEdit(description: long, soul: original.soul).isValid(from: original))
        #expect(BotPersonaEdit(description: String(long.dropLast()), soul: original.soul).isValid(from: original))
        #expect(!BotPersonaEdit(description: "", soul: "  \n").isValid(from: original))
        #expect(!BotPersonaEdit(description: "", soul: String(repeating: "a", count: BotPersona.maximumSoulLength + 1)).isValid(from: original))
        #expect(BotPersonaEdit(description: "", soul: String(repeating: "a", count: BotPersona.maximumSoulLength)).isValid(from: original))
    }

    @Test("save sends only the changed fields")
    func sendsChangedOnly() async {
        let bots = ScriptedBots()
        bots.script("profiles.configure", ["ok": true, "applied": ["soul": true]])
        let result = await client(bots).save(BotPersonaEdit(description: "Plans trips", soul: "new"), changing: [.soul])
        #expect(result == BotPersonaSave(saved: [.soul]))
        #expect(bots.calls(to: "profiles.configure").first?.params == ["name": "atlas", "soul": "new"])
    }

    @Test("applied false for a field is a failure for that field only")
    func appliedFalse() async {
        let bots = ScriptedBots()
        bots.script("profiles.configure", ["ok": false, "applied": ["description": true, "soul": false]])
        let result = await client(bots).save(BotPersonaEdit(description: "Cooks", soul: "new"), changing: [.description, .soul])
        #expect(result == BotPersonaSave(saved: [.description], failed: [.soul]))
    }

    @Test("a missing applied entry and a thrown error both count as not saved")
    func missingOrThrown() async {
        let missing = ScriptedBots()
        missing.script("profiles.configure", ["ok": true])
        #expect(await client(missing).save(BotPersonaEdit(description: "x", soul: original.soul), changing: [.description]).failed == [.description])
        let thrown = ScriptedBots()
        thrown.script("profiles.configure") { _ in throw refusal(5064) }
        #expect(await client(thrown).save(BotPersonaEdit(description: "x", soul: "y"), changing: [.description, .soul]).failed == [.description, .soul])
    }

    @Test("saving nothing makes no call")
    func noChange() async {
        let bots = ScriptedBots()
        #expect(await client(bots).save(BotPersonaEdit(description: "", soul: ""), changing: []) == BotPersonaSave())
        #expect(bots.calls.isEmpty)
    }

    @Test("write-one-for-me returns the description and sends overwrite as asked")
    func describeAuto() async {
        let bots = ScriptedBots()
        bots.script("profiles.describe_auto", ["ok": true, "name": "atlas", "description": " Plans trips. "])
        #expect(await client(bots).describeAutomatically(overwrite: true) == .written("Plans trips."))
        #expect(bots.calls(to: "profiles.describe_auto").first?.params == ["name": "atlas", "overwrite": true])
    }

    @Test("4102 means the owner already wrote one, 4403 not the owner, anything else a retry")
    func describeAutoErrors() async {
        let cases: [(Int, BotDescribeResult)] = [(4102, .alreadyDescribed), (4403, .notOwner), (5101, .failed)]
        for (code, expected) in cases {
            let bots = ScriptedBots()
            bots.script("profiles.describe_auto") { _ in throw refusal(code) }
            #expect(await client(bots).describeAutomatically(overwrite: false) == expected)
            #expect(bots.calls(to: "profiles.describe_auto").first?.params["overwrite"] == false)
        }
    }

    @Test("an empty description from the gateway is a failure")
    func describeAutoEmpty() async {
        let bots = ScriptedBots()
        bots.script("profiles.describe_auto", ["ok": true, "name": "atlas", "description": " "])
        #expect(await client(bots).describeAutomatically(overwrite: false) == .failed)
    }
}

@Suite("Unfinished bot setup")
struct BotSetupUnfinishedTests {
    private func profile(_ name: String, primary: Bool = false, meta: [String: JSONValue]? = nil) async throws -> BotProfile {
        let bots = ScriptedBots()
        bots.script("profiles.list", profilesList(profileRow(name, primary: primary, meta: meta)))
        return try await BotProfileService(gateway: bots.gateway).profile(named: name)
    }

    @Test("a bot with no saved look is unfinished")
    func noLook() async throws {
        #expect(try await profile("atlas").isSetupUnfinished)
        #expect(try await profile("atlas", meta: ["title": "Atlas"]).isSetupUnfinished)
    }

    @Test("a bot with a saved look is finished")
    func hasLook() async throws {
        #expect(try await !profile("atlas", meta: ["shape": "blobatar:ab:cloud", "color": "#10dc69"]).isSetupUnfinished)
    }

    @Test("the main bot and the primary bot never read as unfinished")
    func mainBots() async throws {
        #expect(try await !profile("default").isSetupUnfinished)
        #expect(try await !profile("atlas", primary: true).isSetupUnfinished)
    }
}
