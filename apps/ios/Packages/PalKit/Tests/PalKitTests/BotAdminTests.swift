import Foundation
import PalProtocol
import PalRoster
import PalTransport
import Testing

@Suite("Bot admin")
struct BotAdminTests {
    private func start(_ fake: FakeRoster) async throws -> (BotAdmin, FakeGateway, GatewayConnection) {
        let gateway = try await FakeGateway.start { method, params, connection in fake.handle(method, params, connection) }
        let (rpc, connection) = try await rosterGateway(gateway)
        return (BotAdmin(gateway: rpc), gateway, connection)
    }

    @Test func pinningKeepsEveryOtherKeyTheBotAlreadyHad() async throws {
        let fake = FakeRoster(names: ["default", "cho-ua"])
        fake.seed("cho-ua", meta: [
            "title": "chó UA", "color": "#d6264a", "shape": "blobatar:ua:organic", "custom": true,
            "groups": ["a", "b"], "sectionId": "s1", "section_name": "Work", "created": 1_700_000_000_000,
        ])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        let meta = try await admin.setPinned("cho-ua", pinned: true)

        let stored = try #require(fake.meta("cho-ua"))
        #expect(stored["pinned"] == true)
        for key in ["title", "color", "shape", "custom", "groups", "sectionId", "section_name", "created"] {
            #expect(stored[key] != nil, "\(key) survived")
        }
        #expect(stored["groups"] == ["a", "b"])
        #expect(meta.fields == stored)
        let write = try #require(fake.calls("profiles.configure").first ?? nil)
        #expect(write["ui_meta_expected_revisions"]?[BotMeta.namespace] == 1)
    }

    @Test func unpinningWritesFalseLikeDesktop() async throws {
        let fake = FakeRoster(names: ["cho-ua"])
        fake.seed("cho-ua", meta: ["title": "chó UA", "pinned": true])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.setPinned("cho-ua", pinned: false)

        #expect(fake.meta("cho-ua")?["pinned"] == false)
        #expect(fake.meta("cho-ua")?["title"] == "chó UA")
    }

    @Test func pinningAnAlreadyPinnedBotWritesNothing() async throws {
        let fake = FakeRoster(names: ["cho-ua"])
        fake.seed("cho-ua", meta: ["pinned": true])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.setPinned("cho-ua", pinned: true)

        #expect(fake.calls("profiles.configure").isEmpty)
    }

    @Test func aBotWithNoNamespaceYetStartsFromRevisionZero() async throws {
        let fake = FakeRoster(names: ["fresh"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.setPinned("fresh", pinned: true)

        let write = try #require(fake.calls("profiles.configure").first ?? nil)
        #expect(write["ui_meta_expected_revisions"]?[BotMeta.namespace] == 0)
        #expect(fake.meta("fresh")?["pinned"] == true)
    }

    @Test func aConcurrentWriterCausesAReReadAndNothingTheyWroteIsLost() async throws {
        let fake = FakeRoster(names: ["cho-ua"])
        fake.seed("cho-ua", meta: ["title": "chó UA"])
        fake.state.withLock { $0.raceOnConfigure = [1] }
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.setPinned("cho-ua", pinned: true)

        #expect(fake.calls("profiles.configure").count == 2)
        let stored = try #require(fake.meta("cho-ua"))
        #expect(stored["pinned"] == true)
        #expect(stored["sneaky"] == true)
        #expect(stored["title"] == "chó UA")
        #expect(fake.calls("profiles.list").count == 2)
    }

    @Test func persistentConflictsGiveUpWithATypedError() async throws {
        let fake = FakeRoster(names: ["cho-ua"])
        fake.state.withLock { $0.raceOnConfigure = [1, 2, 3, 4, 5] }
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.conflict) { try await admin.setPinned("cho-ua", pinned: true) }

        #expect(fake.calls("profiles.configure").count == BotMetaWriter.defaultAttempts)
        #expect(fake.meta("cho-ua")?["pinned"] == nil)
    }

    @Test func pinningTwoBotsAtOnceKeepsBothAndTheirOwnMeta() async throws {
        let fake = FakeRoster(names: ["a", "b"])
        fake.seed("a", meta: ["title": "A"])
        fake.seed("b", meta: ["title": "B"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await admin.setPinned("a", pinned: true) }
            group.addTask { try await admin.setPinned("b", pinned: true) }
            try await group.waitForAll()
        }

        #expect(fake.meta("a")?["pinned"] == true && fake.meta("a")?["title"] == "A")
        #expect(fake.meta("b")?["pinned"] == true && fake.meta("b")?["title"] == "B")
    }

    @Test func twoWritersOnTheSameBotConvergeOnBothChanges() async throws {
        let fake = FakeRoster(names: ["a"])
        fake.seed("a", meta: ["title": "A"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }
        let writer = BotMetaWriter(gateway: try await rosterGateway(gateway).0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await admin.setPinned("a", pinned: true) }
            group.addTask {
                try await writer.update("a") { fields in fields.merging(["color": "#ffffff"]) { _, new in new } }
            }
            try await group.waitForAll()
        }

        let stored = try #require(fake.meta("a"))
        #expect(stored["pinned"] == true && stored["color"] == "#ffffff" && stored["title"] == "A")
    }

    @Test func gatewaysWithoutRevisionsStillAcceptThePin() async throws {
        let fake = FakeRoster(names: ["old"])
        fake.state.withLock { $0.omitRevisions = true }
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.setPinned("old", pinned: true)

        let write = try #require(fake.calls("profiles.configure").first ?? nil)
        #expect(write["ui_meta_expected_revisions"] == nil)
        #expect(fake.meta("old")?["pinned"] == true)
    }

    @Test func pinningAnUnknownBotIsBotNotFound() async throws {
        let fake = FakeRoster(names: ["a"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.botNotFound) { try await admin.setPinned("ghost", pinned: true) }
        #expect(fake.calls("profiles.configure").isEmpty)
    }

    @Test func hidingAndShowingKeepsEveryOtherKeyAndIsIndependentOfPinning() async throws {
        let fake = FakeRoster(names: ["cho-ua"])
        fake.seed("cho-ua", meta: ["title": "chó UA", "pinned": true, "color": "#d6264a"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        let hidden = try await admin.setHidden("cho-ua", hidden: true)
        #expect(hidden.isHidden && hidden.isPinned)
        #expect(fake.meta("cho-ua")?["hidden"] == true)
        #expect(fake.meta("cho-ua")?["title"] == "chó UA" && fake.meta("cho-ua")?["color"] == "#d6264a")

        try await admin.setHidden("cho-ua", hidden: false)
        #expect(fake.meta("cho-ua")?["hidden"] == false)
        #expect(fake.meta("cho-ua")?["pinned"] == true)
    }

    @Test func hidingAnAlreadyHiddenBotWritesNothing() async throws {
        let fake = FakeRoster(names: ["a"])
        fake.seed("a", meta: ["hidden": true])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.setHidden("a", hidden: true)

        #expect(fake.calls("profiles.configure").isEmpty)
    }

    @Test func renamingWritesTheTrimmedTitleAndLeavesTheRest() async throws {
        let fake = FakeRoster(names: ["cho-ua", "default"])
        fake.seed("cho-ua", meta: ["title": "chó UA", "pinned": true])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.rename("cho-ua", isPrimary: false, to: "  Ads bot \n")

        #expect(fake.meta("cho-ua")?["title"] == "Ads bot" && fake.meta("cho-ua")?["pinned"] == true)
        #expect(fake.calls("profiles.rename").isEmpty)
    }

    @Test(arguments: ["", "   ", String(repeating: "x", count: 61)])
    func renamingToAnInvalidNameIsRefusedBeforeAnyWrite(proposed: String) async throws {
        let fake = FakeRoster(names: ["a"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.invalidName) { try await admin.rename("a", isPrimary: false, to: proposed) }
        #expect(fake.calls("profiles.configure").isEmpty)
    }

    @Test func deletingRemovesTheProfile() async throws {
        let fake = FakeRoster(names: ["default", "cho-ua"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.delete("cho-ua")

        #expect(fake.state.withLock { $0.names } == ["default"])
        let call = try #require(fake.calls("profiles.delete").first ?? nil)
        #expect(call == ["name": "cho-ua"])
    }

    @Test func deletingAnUnknownBotIsBotNotFound() async throws {
        let fake = FakeRoster(names: ["default"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.botNotFound) { try await admin.delete("ghost") }
    }

    @Test func makingAPrimaryMovesTheCanonicalPointer() async throws {
        let fake = FakeRoster(names: ["default", "cho-ua"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        try await admin.makePrimary("cho-ua")

        #expect(fake.state.withLock { $0.primary } == "cho-ua")
        let call = try #require(fake.calls("profiles.set_primary").first ?? nil)
        #expect(call == ["name": "cho-ua"])
    }

    @Test func aGrantThatCannotAdministerTheInstallGetsPermissionDenied() async throws {
        let fake = FakeRoster(names: ["default", "cho-ua"])
        fake.state.withLock { $0.denyPrimary = true }
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.permissionDenied) { try await admin.makePrimary("cho-ua") }
        #expect(fake.state.withLock { $0.primary } == "default")
    }

    @Test func makingAnUnknownBotPrimaryIsBotNotFound() async throws {
        let fake = FakeRoster(names: ["default"])
        let (admin, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.botNotFound) { try await admin.makePrimary("ghost") }
    }

    @Test func aDeadGatewayIsReportedAsUnavailable() async throws {
        let fake = FakeRoster(names: ["a"])
        let (admin, gateway, connection) = try await start(fake)
        gateway.stop()
        await connection.close()

        await #expect(throws: BotAdminError.unavailable) { try await admin.makePrimary("a") }
        await #expect(throws: BotAdminError.unavailable) { try await admin.setPinned("a", pinned: true) }
    }

    @Test func profilesDecodeThePrimaryFlagMetaAndRevisions() throws {
        let row: JSONValue = [
            "name": "cho-ua", "is_primary": true, "display_name": "chó UA",
            "ui_meta": ["hermes-bots": ["pinned": true, "title": "chó UA", "custom_key": 3]],
            "ui_meta_revisions": ["hermes-bots": 4],
            "canonical_session": ["id": "s1", "resolved_id": "s2", "preview": "hi", "last_active": 12.5],
        ]
        let profile = try #require(RosterProfile(row))
        #expect(profile.isPrimary)
        #expect(profile.botMeta.isPinned)
        #expect(profile.botMeta.revision == 4)
        #expect(profile.botMeta.fields["custom_key"] == 3)
        #expect(profile.canonical?.resolvedID == "s2")
        #expect(RosterProfile(["display_name": "nameless"]) == nil)
        let plain = try #require(RosterProfile(["name": "x", "canonical_session": nil]))
        #expect(!plain.isPrimary && !plain.botMeta.isPinned && plain.botMeta.revision == nil && plain.canonical == nil)
    }
}
