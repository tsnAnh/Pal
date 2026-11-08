import Foundation
import HermesProtocol
import HermesRoster
import HermesTransport
import Synchronization
import Testing

@Suite("Bot provisioner")
struct BotProvisionerTests {
    private static let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func start(_ fake: FakeRoster) async throws -> (BotProvisioner, FakeGateway, GatewayConnection) {
        let gateway = try await FakeGateway.start { method, params, connection in fake.handle(method, params, connection) }
        let (rpc, connection) = try await rosterGateway(gateway)
        return (BotProvisioner(gateway: rpc, now: { Self.stamp }), gateway, connection)
    }

    private func request(_ name: String = "chó Ba Tư", kind: String = "boxy", color: String = "#f58a06") -> NewBotRequest {
        NewBotRequest(name: name, kind: kind, colorHex: color)
    }

    @Test func createsTheProfileThenWritesItsLook() async throws {
        let fake = FakeRoster(names: ["default"])
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        let created = try await provisioner.create(request())

        #expect(created == CreatedBot(name: "cho-ba-tu", displayName: "chó Ba Tư", greetsUnprompted: true))
        let create = try #require(fake.calls("profiles.create").first ?? nil)
        #expect(create["name"] == "cho-ba-tu")
        #expect(create["display_name"] == "chó Ba Tư")
        #expect(create["clone_from"] == "default")
        #expect(create["onboarding"] == nil)
        #expect(create["soul"]?.stringValue?.contains("`cho-ba-tu`") == true)
        let meta = try #require(fake.meta("cho-ba-tu"))
        #expect(meta["title"] == "chó Ba Tư")
        #expect(meta["color"] == "#f58a06")
        #expect(meta["shape"] == "blobatar:cho-ba-tu:boxy")
        #expect(meta["custom"] == true)
        #expect(meta["created"] == .int(1_800_000_000_000))
        #expect(fake.calls("profiles.configure").count == 1)
    }

    @Test func theBirthNoticeFlagDecidesWhetherTheBotGreetsUnprompted() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.state.withLock { $0.birthNotice = false }
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        let created = try await provisioner.create(request("Plain"))

        #expect(created.greetsUnprompted == false)
    }

    @Test func aFailedLookWriteLeavesAnIncompleteBotAndARetryDoesNotRecreateIt() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.state.withLock { $0.failConfigure = 1 }
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.incomplete(profile: "grok")) { try await provisioner.create(request("Grok")) }
        #expect(fake.calls("profiles.create").count == 1)
        #expect(fake.meta("grok") == nil)

        let created = try await provisioner.create(request("Grok"))

        #expect(created.name == "grok")
        #expect(fake.calls("profiles.create").count == 1)
        #expect(fake.meta("grok")?["shape"] == "blobatar:grok:boxy")
    }

    @Test func aRetryKeepsTheOriginalCreationTimestamp() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.state.withLock { $0.failConfigure = 1 }
        let clock = Mutex(Self.stamp)
        let gateway = try await FakeGateway.start { method, params, connection in fake.handle(method, params, connection) }
        let (rpc, connection) = try await rosterGateway(gateway)
        defer { gateway.stop(); Task { await connection.close() } }
        let provisioner = BotProvisioner(gateway: rpc, now: { clock.withLock { $0 } })

        _ = try? await provisioner.create(request("Grok"))
        clock.withLock { $0 = Self.stamp.addingTimeInterval(90) }
        _ = try await provisioner.create(request("Grok"))

        #expect(fake.meta("grok")?["created"] == .int(1_800_000_000_000))
    }

    @Test func renamingAfterAnIncompleteCreateDiscardsTheUnfinishedBot() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.state.withLock { $0.failConfigure = 1 }
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        _ = try? await provisioner.create(request("Grok"))
        let created = try await provisioner.create(request("Grok Two"))

        #expect(created.name == "grok-two")
        let names = fake.state.withLock { $0.names }
        #expect(names == ["default", "grok-two"])
        #expect(fake.calls("profiles.delete").count == 1)
    }

    @Test func aNameAlreadyOnTheGatewayIsNameTakenAndNothingIsCreated() async throws {
        let fake = FakeRoster(names: ["default", "cho-ua"])
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.nameTaken) { try await provisioner.create(request("Chó UA")) }

        #expect(fake.calls("profiles.create").isEmpty)
    }

    @Test func aRaceForTheSameSlugIsNameTakenFromTheGatewaysOwnRefusal() async throws {
        let fake = FakeRoster(names: ["default"])
        let gateway = try await FakeGateway.start { method, params, connection in
            if method == "profiles.list" {
                return .result(["profiles": [["name": "default"]], "bot_birth_notice": true])
            }
            return fake.handle(method, params, connection)
        }
        let (rpc, connection) = try await rosterGateway(gateway)
        defer { gateway.stop(); Task { await connection.close() } }
        fake.seed("grok", meta: [:], revision: 0)
        let provisioner = BotProvisioner(gateway: rpc)

        await #expect(throws: BotAdminError.nameTaken) { try await provisioner.create(request("Grok")) }
    }

    @Test func unusableNamesAreRefusedBeforeAnyCall() async throws {
        let fake = FakeRoster(names: ["default"])
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        for name in ["", "   ", "🤖", "Hermes", "default"] {
            await #expect(throws: BotAdminError.invalidName, "\(name)") { try await provisioner.create(request(name)) }
        }
        await #expect(throws: BotAdminError.invalidName) { try await provisioner.create(request("Ok", color: "orange")) }
        await #expect(throws: BotAdminError.invalidName) { try await provisioner.create(request("Ok", kind: "bad:kind")) }
        #expect(fake.state.withLock { $0.calls.isEmpty })
    }

    @Test func aFailedCreateSurfacesAsUnavailableOrRejectedAndRetriesCleanly() async throws {
        let fake = FakeRoster(names: ["default"])
        fake.state.withLock { $0.failCreate = 1 }
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        await #expect(throws: BotAdminError.rejected) { try await provisioner.create(request("Grok")) }
        #expect(fake.meta("grok") == nil)

        let created = try await provisioner.create(request("Grok"))
        #expect(created.name == "grok")
        #expect(fake.calls("profiles.create").count == 2)
    }

    @Test func concurrentCreatesOfOneNameShareOneFlight() async throws {
        let fake = FakeRoster(names: ["default"])
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        async let first = provisioner.create(request("Grok"))
        async let second = provisioner.create(request("Grok"))
        let results = try await [first, second]

        #expect(results[0] == results[1])
        #expect(fake.calls("profiles.create").count == 1)
    }

    @Test func newKindsFromTheDesignModuleFlowThroughAsPlainStrings() async throws {
        let fake = FakeRoster(names: ["default"])
        let (provisioner, gateway, connection) = try await start(fake)
        defer { gateway.stop(); Task { await connection.close() } }

        _ = try await provisioner.create(request("Spark", kind: "sparkle"))

        #expect(fake.meta("spark")?["shape"] == "blobatar:spark:sparkle")
    }
}
