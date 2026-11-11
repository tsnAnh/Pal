import Foundation
import PalAuth
import PalChat
import PalClient
import PalProtocol
import PalREST
import PalTransport
import Synchronization
import Testing

private struct Call: Sendable {
    var method: String
    var params: JSONValue?
    var connection: Int
}

private final class ReachGateway: Sendable {
    private let calls = Mutex<[Call]>([])
    private let capabilities: Mutex<[String]>
    private let sources: Mutex<[String]>
    private let helloReply: Mutex<FakeGateway.Reply?>
    private let describeReply: Mutex<FakeGateway.Reply?>

    init(
        capabilities: [String] = ["durable-admission-v1", "reach-v1"],
        sources: [String] = ["cli", "tui", "gui", "ios"],
        helloReply: FakeGateway.Reply? = nil,
        describeReply: FakeGateway.Reply? = nil
    ) {
        self.capabilities = Mutex(capabilities)
        self.sources = Mutex(sources)
        self.helloReply = Mutex(helloReply)
        self.describeReply = Mutex(describeReply)
    }

    func handle(_ method: String, _ params: JSONValue?, _ connection: Int) -> FakeGateway.Reply {
        calls.withLock { $0.append(Call(method: method, params: params, connection: connection)) }
        switch method {
        case "runtime.describe":
            if let reply = describeReply.withLock({ $0 }) { return reply }
            return .result([
                "instance_id": "i1", "profile_id": "p1", "authority_epoch": 1,
                "capabilities": .array(capabilities.withLock { $0 }.map(JSONValue.string)),
                "session_create": ["sources": .array(sources.withLock { $0 }.map(JSONValue.string))],
            ])
        case "gateway.ping":
            return .result(["ok": true])
        case "client.hello":
            return helloReply.withLock { $0 } ?? .result(["recorded": true, "same_host": false])
        case "client.attention":
            return .result(["recorded": true])
        case "reach.outcome":
            return .result(["recorded": true])
        case "session.create":
            return .result([
                "session_id": "s1", "messages": [], "running": false, "replay_epoch": "e1", "last_sequence": 0,
                "execution_generation": 1, "pending": [], "prompts": [],
            ])
        default:
            return .failure(RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"]))
        }
    }

    func calls(_ method: String) -> [Call] { calls.withLock { $0.filter { $0.method == method } } }
    var methods: [String] { calls.withLock { $0.map(\.method) } }
}

private struct TicketTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let body = Data(#"{"ticket":"reach-test-ticket","ttl_seconds":60}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return HTTPResult(data: body, response: response)
    }
}

private func identity(_ id: String = "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A") -> DeviceIdentity {
    DeviceIdentity(deviceID: id, formFactor: .phone, appVersion: "0.1.0 (7)")
}

private func client(for gateway: FakeGateway, presence: ReachPresence?) throws -> PalClient {
    let port = try #require(gateway.url.port)
    let base = try GatewayBaseURL(validating: "http://127.0.0.1:\(port)")
    let tokens = TokenSet(accessToken: "access-token-1", refreshToken: "refresh-token-1", expiresAt: Date().addingTimeInterval(3600))
    let auth = try AuthSession(store: InMemoryCredentialStore(StoredCredentials(baseURL: base, tokens: tokens)), transport: TicketTransport())
    return PalClient(auth: auth, transport: TicketTransport(), presence: presence)
}

private func eventually(_ timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func offerEvent(_ id: String = "offer-1", kind: String = "notify", sessionID: String? = "s-1") -> GatewayEvent {
    var payload: [String: JSONValue] = [
        "offer_id": .string(id), "kind": .string(kind), "domain": "cron", "title": "Daily digest", "body": "Three things changed.",
    ]
    if let sessionID { payload["session_id"] = .string(sessionID) }
    return GatewayEvent(type: "reach.offer", payload: .object(payload))
}

@Suite("Device identity")
struct DeviceIdentityTests {
    @Test func labelFollowsFormFactorWithoutDeviceName() {
        #expect(DeviceIdentity(deviceID: "a1b2c3d4", formFactor: .phone, appVersion: "1").label == "iPhone")
        #expect(DeviceIdentity(deviceID: "a1b2c3d4", formFactor: .pad, appVersion: "1").label == "iPad")
        #expect(DeviceIdentity(deviceID: "a1b2c3d4", formFactor: .other, appVersion: "1").label == "iOS device")
    }

    @Test func idIsGeneratedOnceAndStaysStable() throws {
        let store = InMemoryDeviceIDStore()
        let first = DeviceIdentity.resolve(store: store, formFactor: .phone, appVersion: "1")
        let second = DeviceIdentity.resolve(store: store, formFactor: .pad, appVersion: "2")
        #expect(first.deviceID == second.deviceID)
        #expect(DeviceIdentity.isValid(deviceID: first.deviceID))
        #expect(try store.load() == first.deviceID)
    }

    @Test(arguments: ["", "short", "has space in it", "emoji-\u{1F600}-id", String(repeating: "a", count: 65)])
    func malformedStoredIDIsReplaced(stored: String) throws {
        let store = InMemoryDeviceIDStore(stored)
        let resolved = DeviceIdentity.resolve(store: store, formFactor: .phone, appVersion: "1")
        #expect(resolved.deviceID != stored)
        #expect(DeviceIdentity.isValid(deviceID: resolved.deviceID))
        #expect(try store.load() == resolved.deviceID)
    }

    @Test func unavailableStoreStillYieldsAValidID() {
        struct Broken: DeviceIDStore {
            func load() throws -> String? { throw KeychainError.status(-25308) }
            func save(_ deviceID: String) throws { throw KeychainError.status(-25308) }
        }
        let resolved = DeviceIdentity.resolve(store: Broken(), formFactor: .phone, appVersion: "1")
        #expect(DeviceIdentity.isValid(deviceID: resolved.deviceID))
    }

    @Test func versionIsBoundedToTheWireLimit() {
        let long = String(repeating: "9", count: 80)
        #expect(DeviceIdentity(deviceID: "a1b2c3d4", formFactor: .phone, appVersion: long).appVersion.count == DeviceIdentity.maximumVersionLength)
    }

    @Test func appVersionJoinsMarketingAndBuild() {
        #expect(DeviceIdentity.appVersion(of: .main).count <= 64)
    }
}

@Suite("Reach wire")
struct ReachWireTests {
    @Test func helloPayloadMatchesTheContract() {
        let params = ReachWire.helloParams(identity: identity(), acceptsOffers: true, attention: .foreground)
        #expect(params == [
            "kind": "ios",
            "device_id": "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A",
            "label": "iPhone",
            "app_version": "0.1.0 (7)",
            "accepts_offers": true,
            "attention": "foreground",
        ])
        #expect(DeviceIdentity.isValid(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A"))
    }

    @Test func aMacDeclaresItselfAsAMacAndPhonesStayIOS() {
        let mac = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .mac, appVersion: "0.1.0 (7)")
        #expect(ReachWire.helloParams(identity: mac, acceptsOffers: true, attention: .foreground)["kind"] == "mac")
        #expect(ReachWire.helloParams(identity: mac, acceptsOffers: true, attention: .foreground)["label"] == "Mac")
        for factor in [DeviceFormFactor.phone, .pad, .other] {
            let identity = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: factor, appVersion: "1")
            #expect(ReachWire.helloParams(identity: identity, acceptsOffers: false, attention: .background)["kind"] == "ios")
        }
    }

    @Test func attentionAndOutcomePayloads() {
        #expect(ReachWire.attentionParams(.background) == ["state": "background"])
        #expect(ReachWire.outcomeParams(offerID: "o1", outcome: .acted) == ["offer_id": "o1", "outcome": "acted"])
    }

    @Test func sceneMapsToAttention() {
        #expect(ReachAttention(sceneIsActive: true) == .foreground)
        #expect(ReachAttention(sceneIsActive: false) == .background)
    }

    @Test func offerDecodesTheWirePayload() throws {
        let offer = try #require(ReachOffer(event: offerEvent("o-9", kind: "suggest", sessionID: "s-7")))
        #expect(offer == ReachOffer(offerID: "o-9", kind: .suggest, domain: "cron", title: "Daily digest", body: "Three things changed.", sessionID: "s-7"))
        #expect(ReachOffer(event: offerEvent(sessionID: nil))?.sessionID == nil)
    }

    @Test func malformedOffersAreRejected() {
        #expect(ReachOffer(event: offerEvent("")) == nil)
        #expect(ReachOffer(event: offerEvent(String(repeating: "x", count: 65))) == nil)
        #expect(ReachOffer(event: offerEvent(kind: "act")) == nil)
        #expect(ReachOffer(event: GatewayEvent(type: "reach.offer", payload: ["offer_id": "o"])) == nil)
        #expect(ReachOffer(event: GatewayEvent(type: "sessions.changed", payload: nil)) == nil)
    }

    @Test func createSourceFollowsAdvertisedSources() {
        func advertised(_ sources: [String]?) -> JSONValue {
            var object: [String: JSONValue] = ["instance_id": "i", "profile_id": "p", "authority_epoch": 1, "capabilities": []]
            if let sources { object["session_create"] = ["sources": .array(sources.map(JSONValue.string))] }
            return .object(object)
        }
        #expect(RuntimeDescription.createSource(advertised: advertised(["cli", "gui", "ios"])) == "ios")
        #expect(RuntimeDescription.createSource(advertised: advertised(["cli", "gui"])) == "gui")
        #expect(RuntimeDescription.createSource(advertised: advertised(nil)) == "gui")
        #expect(RuntimeDescription.createSource(advertised: nil) == "gui")
        #expect(RuntimeDescription.createSource(advertised: "garbage") == "gui")
    }
}

@Suite("Reach presence over a gateway")
struct ReachPresenceTests {
    @Test func connectDeclaresTheDeviceWhenReachIsAdvertised() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let connection = try await client(for: gateway, presence: presence).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        let hello = try #require(script.calls("client.hello").first)
        #expect(hello.params == ReachWire.helloParams(identity: identity(), acceptsOffers: true, attention: .foreground))
        #expect(script.methods.firstIndex(of: "runtime.describe")! < script.methods.firstIndex(of: "client.hello")!)
    }

    @Test func passiveConnectionsDoNotAcceptOffers() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let connection = try await client(for: gateway, presence: ReachPresence(identity: identity())).connect()
        defer { Task { await connection.close() } }
        let hello = try #require(script.calls("client.hello").first)
        #expect(hello.params?["accepts_offers"]?.boolValue == false)
    }

    @Test func noHelloWithoutTheCapability() async throws {
        let script = ReachGateway(capabilities: ["durable-admission-v1"])
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let connection = try await client(for: gateway, presence: ReachPresence(identity: identity())).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        #expect(script.calls("client.hello").isEmpty)
    }

    @Test func noHelloWithoutAPresence() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let connection = try await client(for: gateway, presence: nil).connect()
        defer { Task { await connection.close() } }
        #expect(script.calls("client.hello").isEmpty)
        #expect(connection.negotiatedRuntime != nil)
    }

    @Test func aGatewayThatDoesNotKnowTheMacKindStillRecordsTheDeviceAsIOS() async throws {
        let kinds = Mutex<[String]>([])
        let gateway = try await FakeGateway.start { method, params, _ in
            switch method {
            case "runtime.describe":
                return .result([
                    "instance_id": "i1", "profile_id": "p1", "authority_epoch": 1, "capabilities": ["durable-admission-v1", "reach-v1"],
                    "session_create": ["sources": ["cli", "ios"]],
                ])
            case "client.hello":
                let kind = params?["kind"]?.stringValue ?? ""
                kinds.withLock { $0.append(kind) }
                return kind == "mac" ? .failure(RPCError(code: -32602, message: "invalid_params")) : .result(["recorded": true, "same_host": false])
            default:
                return .result(["ok": true])
            }
        }
        defer { gateway.stop() }
        let mac = DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .mac, appVersion: "1")
        let presence = ReachPresence(identity: mac)
        let connection = try await client(for: gateway, presence: presence).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        #expect(kinds.withLock { $0 } == ["mac", "ios"])
    }

    @Test func refusedHelloLeavesTheConnectionUsable() async throws {
        let refusal = RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"])
        let script = ReachGateway(helloReply: .failure(refusal))
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let connection = try await client(for: gateway, presence: presence).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        await presence.setAttention(.background)
        #expect(script.calls("client.attention").isEmpty)
        #expect(await presence.report(.shown, for: "o1") == false)
        try await connection.ping()
    }

    @Test func backendWithoutRuntimeDescribeStillConnects() async throws {
        let refusal = RPCError(code: -32601, message: "unknown_method", data: ["reason": "unknown_method"])
        let script = ReachGateway(describeReply: .failure(refusal))
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let connection = try await client(for: gateway, presence: ReachPresence(identity: identity())).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        #expect(script.calls("client.hello").isEmpty)
        #expect(connection.negotiatedRuntime == nil)
    }

    @Test func helloIsResentOnEveryReconnectWithTheSameIdentity() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let reach = try client(for: gateway, presence: presence)
        let first = try await reach.connect(reach: .offerTarget)
        gateway.dropAll()
        #expect(await eventually { gateway.liveConnectionCount == 0 })
        await first.close()
        let second = try await reach.connect(reach: .offerTarget)
        defer { Task { await second.close() } }
        let hellos = script.calls("client.hello")
        #expect(hellos.count == 2)
        #expect(hellos[0].connection != hellos[1].connection)
        #expect(hellos[0].params?["device_id"] == hellos[1].params?["device_id"])
    }

    @Test func reconnectHelloCarriesTheLatestAttention() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let reach = try client(for: gateway, presence: presence)
        let first = try await reach.connect(reach: .offerTarget)
        await presence.setAttention(.background)
        await first.close()
        let second = try await reach.connect(reach: .offerTarget)
        defer { Task { await second.close() } }
        let hellos = script.calls("client.hello")
        #expect(hellos.last?.params?["attention"]?.stringValue == "background")
    }

    @Test func attentionIsSentOnlyOnChange() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let connection = try await client(for: gateway, presence: presence).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        await presence.setAttention(.foreground)
        await presence.setAttention(.background)
        await presence.setAttention(.background)
        await presence.setAttention(.foreground)
        await presence.setAttention(.foreground)
        let states = script.calls("client.attention").compactMap { $0.params?["state"]?.stringValue }
        #expect(states == ["background", "foreground"])
        #expect(await presence.currentAttention == .foreground)
    }

    @Test func burstOfChangesConvergesOnTheFinalState() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let connection = try await client(for: gateway, presence: presence).connect(reach: .offerTarget)
        defer { Task { await connection.close() } }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<9 {
                group.addTask { await presence.setAttention(index.isMultiple(of: 2) ? .background : .foreground) }
            }
        }
        let final = await presence.currentAttention
        #expect(await eventually {
            script.calls("client.attention").last?.params?["state"]?.stringValue == final.rawValue
        })
    }

    @Test func attentionReachesEveryDeclaredConnection() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let reach = try client(for: gateway, presence: presence)
        let target = try await reach.connect(reach: .offerTarget)
        let passive = try await reach.connect()
        defer { Task { await target.close(); await passive.close() } }
        await presence.setAttention(.background)
        let connections = Set(script.calls("client.attention").map(\.connection))
        #expect(connections.count == 2)
    }

    @Test func closedConnectionsStopReceivingAttention() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let connection = try await client(for: gateway, presence: presence).connect(reach: .offerTarget)
        await connection.close()
        await presence.setAttention(.background)
        await presence.setAttention(.foreground)
        #expect(script.calls("client.attention").isEmpty)
    }

    @Test func offersCanOnlyBePresentedWhileTheAppIsInTheForeground() async {
        let presence = ReachPresence(identity: identity())
        #expect(await presence.canPresentOffers)
        await presence.setAttention(.background)
        #expect(await presence.canPresentOffers == false)
        await presence.setAttention(.foreground)
        #expect(await presence.canPresentOffers)
    }

    @Test func offersAreDedupedByID() async throws {
        let presence = ReachPresence(identity: identity())
        presence.receive(offerEvent("o-1"))
        presence.receive(offerEvent("o-1"))
        presence.receive(GatewayEvent(type: "sessions.changed"))
        presence.receive(offerEvent("o-bad", kind: "act"))
        presence.receive(offerEvent("o-2"))
        presence.receive(offerEvent("o-1"))
        var iterator = presence.offers.makeAsyncIterator()
        #expect(await iterator.next()?.offerID == "o-1")
        #expect(await iterator.next()?.offerID == "o-2")
    }

    @Test func outcomesTravelOnTheOfferTargetConnectionAndOnlyMoveForward() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let reach = try client(for: gateway, presence: presence)
        let target = try await reach.connect(reach: .offerTarget)
        let passive = try await reach.connect()
        defer { Task { await target.close(); await passive.close() } }
        let targetIndex = try #require(script.calls("client.hello").first { $0.params?["accepts_offers"]?.boolValue == true }?.connection)

        #expect(await presence.report(.shown, for: "o-1"))
        #expect(await presence.report(.shown, for: "o-1") == false)
        #expect(await presence.report(.acted, for: "o-1"))
        #expect(await presence.report(.shown, for: "o-1") == false)
        #expect(await presence.report(.dismissed, for: "o-1") == false)

        let sent = script.calls("reach.outcome")
        #expect(sent.compactMap { $0.params?["outcome"]?.stringValue } == ["shown", "acted"])
        #expect(Set(sent.map(\.connection)) == [targetIndex])
        #expect(sent.allSatisfy { $0.params?["offer_id"]?.stringValue == "o-1" })
    }

    @Test func outcomeWithoutAnOfferTargetIsDropped() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let presence = ReachPresence(identity: identity())
        let connection = try await client(for: gateway, presence: presence).connect()
        defer { Task { await connection.close() } }
        #expect(await presence.report(.shown, for: "o-1") == false)
        #expect(script.calls("reach.outcome").isEmpty)
    }
}

@Suite("Session source")
struct SessionSourceTests {
    private func createdSource(sources: [String]) async throws -> String? {
        let script = ReachGateway(sources: sources)
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let connection = try await client(for: gateway, presence: nil).connect()
        defer { Task { await connection.close() } }
        _ = try await SessionAPI(connection: connection, profile: "default").create(title: "Bot Chat", requestID: "r1", hidden: true)
        return script.calls("session.create").first?.params?["source"]?.stringValue
    }

    @Test func usesIosWhenTheGatewayAdvertisesIt() async throws {
        #expect(try await createdSource(sources: ["cli", "gui", "ios", "tui"]) == "ios")
    }

    @Test func fallsBackToGuiForOlderGateways() async throws {
        #expect(try await createdSource(sources: ["cli", "gui", "tui"]) == "gui")
    }

    @Test func fallsBackToGuiWhenNothingWasNegotiated() async throws {
        let script = ReachGateway()
        let gateway = try await FakeGateway.start { method, params, connection in script.handle(method, params, connection) }
        defer { gateway.stop() }
        let connection = try await GatewayConnection.dial(url: gateway.url, ticket: "t")
        defer { Task { await connection.close() } }
        _ = try await SessionAPI(connection: connection, profile: "default").create(title: "Bot Chat", requestID: "r1", hidden: true)
        #expect(script.calls("session.create").first?.params?["source"]?.stringValue == "gui")
    }
}
