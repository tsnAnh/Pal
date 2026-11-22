import Foundation
import PalBotProfile
import PalProtocol
import PalTransport
import Testing

private actor FakeMemberClient: ChatMemberClient {
    var stored = ChatAudienceWire(policy: .ownerOnly, members: [], includeRestricted: false, memberTurnsPerHour: 30, revision: 3)
    var deskItem: ChatDeskItemWire
    var staleOnce = false
    var applied: [ChatAudienceChange] = []

    init() {
        deskItem = ChatDeskItemWire(id: "D1", kind: .handoff, state: .open, revision: 0, createdAt: 1, expiresAt: 2, text: "Post it")
    }

    func bumpElsewhere() { stored.revision += 1; staleOnce = true }

    func audience(_ scope: ChatInstallScope) async throws -> ChatAudienceWire { stored }

    func setAudience(_ scope: ChatInstallScope, _ change: ChatAudienceChange) async throws -> ChatAudienceWire {
        if change.expectedRevision != stored.revision { throw ChatInstallClientError.staleRevision }
        applied.append(change)
        stored.policy = change.policy
        stored.revision += 1
        return stored
    }

    func people(_ scope: ChatInstallScope, query: String, cursor: String?) async throws -> ChatPeoplePageWire {
        ChatPeoplePageWire(people: [], nextCursor: nil)
    }

    func report(_ scope: ChatInstallScope) async throws -> ChatReportDestinationWire { .ownerDirectMessages }

    func setReport(_ scope: ChatInstallScope, _ destination: ChatReportDestinationWire) async throws -> ChatReportDestinationWire {
        if destination.spaceId == "C0" { throw ChatInstallClientError.notJoined }
        return destination
    }

    func leave(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceLeaveOutcome { .left }

    func desk() async throws -> [ChatDeskItemWire] { deskItem.isWaiting ? [deskItem] : [] }

    func decide(itemId: String, choice: ChatDeskChoice, expectedRevision: Int) async throws -> ChatDeskItemWire {
        if expectedRevision != deskItem.revision { throw ChatInstallClientError.staleRevision }
        deskItem.state = choice == .approve ? .done : .declined
        deskItem.revision += 1
        return deskItem
    }

    func decideElsewhere() { deskItem.state = .declined; deskItem.revision += 1 }
}

@MainActor
struct ChatMembersModelTests {
    private let scope = ChatInstallScope(provider: "slack", workspace: "T1")

    @Test func aStaleAudienceChangeReloadsAndTellsTheOwner() async {
        let client = FakeMemberClient()
        let model = ChatMembersModel(client: client)
        await model.load(scope: scope)
        await client.bumpElsewhere()
        await model.setPolicy(.workspace)
        #expect(model.notice == .changedElsewhere)
        #expect(model.audience?.revision == 4)
        #expect(model.audience?.policy == .ownerOnly)
        await model.setPolicy(.workspace)
        #expect(model.audience?.policy == .workspace)
    }

    @Test func reportingToAChannelTheBotLeftIsRefused() async {
        let model = ChatMembersModel(client: FakeMemberClient())
        await model.load(scope: scope)
        await model.setReport(.space(id: "C0", name: "gone"))
        #expect(model.notice == .notJoined)
        #expect(model.report == .ownerDirectMessages)
    }

    @Test func aDeskDecisionUsesTheRevisionTheOwnerSawAndRefreshesWhenStale() async {
        let client = FakeMemberClient()
        let desk = ChatDeskModel(client: client)
        await desk.load()
        #expect(desk.cards.count == 1)
        await client.decideElsewhere()
        await desk.decide("D1", .approve)
        #expect(desk.cards.isEmpty || desk.cards.allSatisfy { !$0.item.isWaiting })
        #expect(desk.cards.first?.answer == nil)
    }

    @Test func approvingMovesTheCardToItsFinalState() async {
        let desk = ChatDeskModel(client: FakeMemberClient())
        await desk.load()
        await desk.decide("D1", .approve)
        #expect(desk.cards.first?.item.state == .done)
    }

    @Test func wireModelsDecodeTheGatewayShapes() throws {
        let json = """
        {"id":"D1","kind":"handoff","state":"open","revision":2,"created_at":1.5,"expires_at":9.5,
         "requester":{"id":"U1","name":"Minh"},"where":{"conversation_id":"C1","thread_ts":null,"label":"#ann"},
         "text":"Post it","why":null,"recipient":null}
        """
        let item = try JSONDecoder().decode(ChatDeskItemWire.self, from: Data(json.utf8))
        #expect(item.place.label == "#ann" && item.requester?.name == "Minh" && item.isWaiting)
        let audience = try JSONDecoder().decode(ChatAudienceWire.self, from: Data("""
        {"policy":"listed","include_restricted":true,"member_turns_per_hour":20,"revision":7,"members":[{"id":"U1","name":"Minh"}]}
        """.utf8))
        #expect(audience.policy == .listed && audience.includeRestricted && audience.members.first?.name == "Minh")
        let report = try JSONDecoder().decode(ChatReportResult.self, from: Data(#"{"destination":{"kind":"space","space_id":"C1","name":"general"}}"#.utf8))
        #expect(report.destination.spaceId == "C1")
    }
}
