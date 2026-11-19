import Foundation
import PalDiagnostics
import PalProtocol
@testable import PalRoster
import PalTransport
import Testing

@Suite("Lookless bot fill")
struct LooklessFillTests {
    private static let palette = LookPalette(
        kinds: ["round", "cloud", "boxy", "spark", "clover", "nub", "sun", "droplet", "capsule", "triangle", "gem", "burst", "hexagon"],
        colors: ["#ffffff", "#845634", "#ed0a37", "#f15105", "#f58a06", "#10dc69", "#0ec79b", "#1b7af8", "#833cf8", "#ee0d8f", "#6c6c6c"]
    )

    private struct Rig {
        let rpc: RosterGateway
        let gateway: FakeGateway
        let connection: GatewayConnection

        func shutdown() {
            gateway.stop()
            let connection = connection
            Task { await connection.close() }
        }
    }

    private func start(_ fake: FakeRoster) async throws -> Rig {
        let gateway = try await FakeGateway.start { method, params, connection in fake.handle(method, params, connection) }
        let (rpc, connection) = try await rosterGateway(gateway)
        return Rig(rpc: rpc, gateway: gateway, connection: connection)
    }

    private func listed(_ rpc: RosterGateway) async throws -> [RosterProfile] {
        try await BotMetaWriter(gateway: rpc).listing().profiles
    }

    private func profile(_ name: String, _ extra: [String: JSONValue] = [:]) throws -> RosterProfile {
        var row: [String: JSONValue] = ["name": .string(name)]
        for (key, value) in extra { row[key] = value }
        return try #require(RosterProfile(.object(row)))
    }

    @Test func theLookIsStablePerNameAndDiffersAcrossNames() {
        let first = LooklessFill.look(for: "atlas", palette: Self.palette)
        #expect(first == LooklessFill.look(for: "atlas", palette: Self.palette))
        #expect(first["shape"] == "blobatar:atlas:clover")
        #expect(first["color"] == "#6c6c6c")
        #expect(LooklessFill.look(for: "hermes-fork-sync", palette: Self.palette)["shape"] == "blobatar:hermes-fork-sync:burst")
        #expect(LooklessFill.look(for: "hermes-fork-sync", palette: Self.palette)["color"] == "#1b7af8")
        #expect(first != LooklessFill.look(for: "scout", palette: Self.palette))
        #expect(LooklessFill.fnv1a("atlas") == 0x890c_8c80_c57b_984c)
    }

    @Test func aLooklessBotGetsExactlyOneWriteWithTheExpectedFields() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("atlas", meta: [:])
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc
        let filler = LooklessFiller(gateway: rpc, palette: Self.palette)

        await filler.fill(try await listed(rpc))

        let meta = try #require(fake.meta("atlas"))
        #expect(meta["title"] == "Atlas")
        #expect(meta["shape"] == "blobatar:atlas:clover")
        #expect(meta["color"] == "#6c6c6c")
        #expect(meta["custom"] == true)
        #expect(meta["imageKind"] == "shape")
        #expect(meta["created"] == nil)
        #expect(fake.calls("profiles.configure").count == 1)
        #expect(fake.calls("profiles.create").isEmpty)
        #expect(fake.meta("default")?.isEmpty ?? true)
    }

    @Test func anExistingTitleIsKept() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("atlas", meta: ["title": "Atlas Prime", "pinned": true])
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc

        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(try await listed(rpc))

        #expect(fake.meta("atlas")?["title"] == "Atlas Prime")
        #expect(fake.meta("atlas")?["pinned"] == true)
        #expect(fake.meta("atlas")?["shape"] == "blobatar:atlas:clover")
    }

    @Test func aSecondLoadAfterTheWriteDoesNotWriteAgain() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("atlas", meta: [:])
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc

        let stale = try await listed(rpc)
        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(stale)
        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(try await listed(rpc))
        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(stale)

        #expect(fake.calls("profiles.configure").count == 1)
    }

    @Test func aBotWithAPhotoOrAnyExistingLookIsNeverWritten() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("photo", meta: ["imageKind": "photo", "image": "x.png"])
        fake.seed("styled", meta: ["shape": "blobatar:ab:cloud", "color": "#10dc69"])
        fake.seed("shaped", meta: ["shape": "blobatar:ab:cloud"])
        fake.seed("coloured", meta: ["color": "#10dc69"])
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc
        let withAvatarFlag = try profile("uploaded", ["has_avatar": true])

        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(try await listed(rpc) + [withAvatarFlag])

        #expect(fake.calls("profiles.configure").isEmpty)
        #expect(fake.meta("shaped")?["color"] == nil)
        #expect(fake.meta("coloured")?["shape"] == nil)
    }

    @Test func thePrimaryAndTheDefaultBotAreNeverFilled() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("lead", meta: [:])
        fake.state.withLock { $0.primary = "lead" }
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc

        let profiles = try await listed(rpc)
        #expect(profiles.filter(LooklessFill.isEligible).isEmpty)
        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(profiles)

        #expect(fake.calls("profiles.configure").isEmpty)
    }

    @Test func aWriterFailureLogsOnceKeepsGoingAndALaterRunRetries() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("atlas", meta: [:])
        fake.seed("scout", meta: [:])
        fake.state.withLock { $0.failConfigure = 1 }
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc
        let recorder = DiagnosticRecorder()

        await LooklessFiller(gateway: rpc, palette: Self.palette, diagnostics: recorder.diagnostics).fill(try await listed(rpc))

        let warnings = recorder.events.filter { $0.level == .warning }
        #expect(warnings.count == 1)
        #expect(warnings.first?.message.contains("atlas") == true)
        #expect(fake.meta("atlas")?["shape"] == nil)
        #expect(fake.meta("scout")?["shape"] == "blobatar:scout:boxy")

        await LooklessFiller(gateway: rpc, palette: Self.palette, diagnostics: recorder.diagnostics).fill(try await listed(rpc))

        #expect(fake.meta("atlas")?["shape"] == "blobatar:atlas:clover")
        #expect(recorder.events.filter { $0.level == .warning }.count == 1)
    }

    @Test func theAvatarBeforeTheWriteEqualsWhatIsWritten() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("atlas", meta: ["pinned": true])
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc
        let listing = try await listed(rpc)
        let before = try #require(listing.first { $0.name == "atlas" })
        let shown = try #require(LooklessFill.effectiveUIMeta(for: before, palette: Self.palette)?[BotMeta.namespace]?.objectValue)

        await LooklessFiller(gateway: rpc, palette: Self.palette).fill([before])

        #expect(shown == fake.meta("atlas"))
        let relisted = try await listed(rpc)
        let after = try #require(relisted.first { $0.name == "atlas" })
        #expect(LooklessFill.effectiveUIMeta(for: after, palette: Self.palette) == after.uiMeta)
    }

    @Test func theFillOnlyReadsTheListingAndConfiguresTheBot() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.seed("atlas", meta: [:])
        let rig = try await start(fake)
        defer { rig.shutdown() }
        let rpc = rig.rpc
        let profiles = try await listed(rpc)
        let before = fake.state.withLock { $0.calls.count }

        await LooklessFiller(gateway: rpc, palette: Self.palette).fill(profiles)

        let methods = fake.state.withLock { Array($0.calls.dropFirst(before).map(\.method)) }
        #expect(methods == ["profiles.list", "profiles.configure"])
    }
}
