import Foundation
import HermesBotProfile
import HermesProtocol
import Testing

@Suite("Rooms")
struct RoomsTests {
    private func roomJSON(_ id: String = "r1", name: String = "Team", epoch: Int = 1, latest: Int = 0) -> JSONValue {
        [
            "room_id": .string(id), "name": .string(name), "authority_epoch": .int(epoch), "latest_seq": .int(latest),
            "updated_at": .int(100),
            "members": [
                ["member_id": "a", "profile": "a", "handle": "a", "display_name": "Alpha"],
                ["member_id": "b", "profile": "b", "handle": "b"],
            ],
        ]
    }

    private func event(_ seq: Int, kind: String = "message.member", actor: JSONValue = ["kind": "member", "id": "a"], text: String = "hi") -> JSONValue {
        ["seq": .int(seq), "event_id": .string("e\(seq)"), "kind": .string(kind), "actor": actor, "payload": ["text": .string(text)], "created_at": .int(200)]
    }

    private func approval(requestID: String? = "req1", command: String = "ls", choices: [String] = ["once", "deny"]) -> JSONValue {
        var action: [String: JSONValue] = [
            "kind": "approval", "member_id": "a", "task_id": "t1", "execution_generation": 2,
            "approval": ["command": .string(command), "description": "list files", "choices": .array(choices.map(JSONValue.string))],
        ]
        if let requestID { action["request_id"] = .string(requestID) }
        return .object(action)
    }

    @Test("a roster needs two to six distinct seats and never the reserved handles")
    func rosterRules() throws {
        #expect(throws: RoomError.invalidRoster(.groupSize)) { try RoomRoster.members(for: [.init(profile: "a")], seatable: nil) }
        let seven = (0..<7).map { RoomRoster.Seat(profile: "p\($0)") }
        #expect(throws: RoomError.invalidRoster(.groupSize)) { try RoomRoster.members(for: seven, seatable: nil) }
        #expect(throws: RoomError.invalidRoster(.duplicateMember)) { try RoomRoster.members(for: [.init(profile: "a"), .init(profile: "A")], seatable: nil) }
        #expect(throws: RoomError.invalidRoster(.duplicateMember)) { try RoomRoster.members(for: [.init(profile: "all"), .init(profile: "b")], seatable: nil) }
        #expect(throws: RoomError.invalidRoster(.notSeatable)) { try RoomRoster.members(for: [.init(profile: "a"), .init(profile: "b")], seatable: ["a"]) }
    }

    @Test("create seats only local profiles of the signed-in account and scopes the call to the room profile")
    func createIsLocalOnly() async throws {
        let bots = ScriptedBots()
        bots.script("groups.create", ["room": roomJSON()])
        let room = try await RoomsService(gateway: bots.gateway, profile: "default")
            .create(roomID: "r1", name: "  Team ", seats: [.init(profile: "a", displayName: "Alpha"), .init(profile: "b")], seatable: nil)
        #expect(room.roomID == "r1")
        let params = try #require(bots.calls.first?.params)
        #expect(params["profile"] == "default")
        #expect(params["name"] == "Team")
        let members = try #require(params["members"]?.arrayValue)
        #expect(members.map { $0["target"]?["kind"]?.stringValue } == ["local", "local"])
        #expect(members.first?["display_name"] == "Alpha")
        #expect(members.allSatisfy { $0["target"]?["peer_id"] == nil })
    }

    @Test("an empty or oversized name never reaches the gateway")
    func nameValidation() async {
        let bots = ScriptedBots()
        let service = RoomsService(gateway: bots.gateway, profile: "default")
        await #expect(throws: RoomError.invalidName) {
            try await service.create(roomID: "r", name: "  ", seats: [.init(profile: "a"), .init(profile: "b")], seatable: nil)
        }
        await #expect(throws: RoomError.invalidName) { try await service.rename(roomID: "r", eventID: "e", name: String(repeating: "x", count: 200)) }
        #expect(bots.calls.isEmpty)
    }

    @Test("listing follows next_offset and orders newest first")
    func listPages() async throws {
        let bots = ScriptedBots()
        let old = roomJSON("old")
        var newer = roomJSON("new")
        if case .object(var object) = newer { object["updated_at"] = .int(900); newer = .object(object) }
        bots.script("groups.list", ["rooms": [old], "next_offset": 1])
        bots.script("groups.list", ["rooms": [newer], "next_offset": nil])
        let rooms = try await RoomsService(gateway: bots.gateway, profile: "default").list()
        #expect(rooms.map(\.roomID) == ["new", "old"])
        #expect(bots.calls(to: "groups.list").compactMap { $0.params["offset"]?.intValue } == [0, 1])
    }

    @Test("a list cursor that does not advance is an error")
    func listCursorStalls() async {
        let bots = ScriptedBots()
        bots.script("groups.list", ["rooms": [], "next_offset": 0])
        await #expect(throws: RoomError.invalidCursor) { try await RoomsService(gateway: bots.gateway, profile: "default").list() }
    }

    @Test("events decode with member attribution, notices and attachments")
    func eventDecoding() throws {
        let room = try #require(Room(roomJSON()))
        let reply = try #require(RoomEvent(event(1, text: "from alpha")))
        #expect(reply.isMessage && reply.isFromMember)
        #expect(reply.author(in: room) == "Alpha")
        let beta = try #require(RoomEvent(event(2, actor: ["kind": "member", "id": "b"])))
        #expect(beta.author(in: room) == "b")
        let named = try #require(RoomEvent(event(3, actor: ["kind": "member", "id": "z", "display_name": "Zed"])))
        #expect(named.author(in: room) == "Zed")
        let you = try #require(RoomEvent(event(4, kind: "message.user", actor: ["kind": "user", "id": "desktop"])))
        #expect(you.author(in: room) == nil && !you.isFromMember)
        let failed = try #require(RoomEvent(event(5, kind: "turn.failed")))
        #expect(failed.notice == .turnFailed && !failed.isMessage)
        let withFile = try #require(RoomEvent([
            "seq": 6, "event_id": "e6", "kind": "message.member", "actor": ["kind": "member", "id": "a"],
            "payload": ["text": "see", "attachments": [["attachment_id": "x1", "kind": "image", "name": "a.png", "mime": "image/png", "size": 12]]],
        ]))
        #expect(withFile.attachments.map(\.attachmentID) == ["x1"])
        #expect(RoomEvent(["kind": "message"]) == nil)
    }

    @Test("the log restarts on a new authority epoch or when it falls behind, and ignores duplicates")
    func logCursor() throws {
        var log = RoomLog()
        let first = try #require(Room(roomJSON(epoch: 1, latest: 2)))
        #expect(log.since(for: first) == 0)
        log.apply(room: first, since: 0, events: [RoomEvent(event(1)), RoomEvent(event(2))].compactMap { $0 })
        #expect(log.lastSeq == 2 && log.since(for: first) == 2)
        log.apply(room: first, since: 2, events: [RoomEvent(event(2)), RoomEvent(event(3))].compactMap { $0 })
        #expect(log.events.map(\.seq) == [1, 2, 3])
        let newEpoch = try #require(Room(roomJSON(epoch: 2, latest: 3)))
        #expect(log.since(for: newEpoch) == 0)
        let behind = try #require(Room(roomJSON(epoch: 1, latest: 1)))
        #expect(log.since(for: behind) == 0)
        log.apply(room: newEpoch, since: 0, events: [RoomEvent(event(1))].compactMap { $0 })
        #expect(log.events.map(\.seq) == [1])
    }

    @Test("refresh reads state, then pages the log from the cursor")
    func refreshPages() async throws {
        let bots = ScriptedBots()
        bots.script("groups.state", ["room": roomJSON(latest: 3), "driver_status": ["working": true, "member_activity": [["member_id": "a", "status": "working"]]]])
        bots.script("groups.log", ["events": [event(1), event(2)], "has_more": true])
        bots.script("groups.log", ["events": [event(3)], "has_more": false])
        let result = try await RoomsService(gateway: bots.gateway, profile: "default").refresh(roomID: "r1", log: RoomLog())
        #expect(result.events.map(\.seq) == [1, 2, 3])
        #expect(result.snapshot.driver?.busyMembers == ["a"])
        #expect(bots.calls(to: "groups.log").compactMap { $0.params["since_seq"]?.intValue } == [0, 2])
    }

    @Test("a log page that makes no progress is an error, not a loop")
    func logStalls() async {
        let bots = ScriptedBots()
        bots.script("groups.state", ["room": roomJSON()])
        bots.script("groups.log", ["events": [], "has_more": true])
        await #expect(throws: RoomError.invalidCursor) {
            try await RoomsService(gateway: bots.gateway, profile: "default").refresh(roomID: "r1", log: RoomLog())
        }
    }

    @Test("send carries the event id as the idempotency key and thread, with attachments")
    func sendPayload() async throws {
        let bots = ScriptedBots()
        bots.script("groups.send", ["event": event(9)])
        let attachment = try #require(RoomAttachment(["attachment_id": "x1", "kind": "file", "name": "n.txt", "mime": "text/plain", "size": 3]))
        try await RoomsService(gateway: bots.gateway, profile: "default").send(roomID: "r1", eventID: "ev", text: "@a hi", attachments: [attachment])
        let params = try #require(bots.calls.first?.params)
        #expect(params["event_id"] == "ev" && params["room_id"] == "r1" && params["profile"] == "default")
        #expect(params["payload"]?["text"] == "@a hi")
        #expect(params["payload"]?["thread_id"] == "ev")
        #expect(params["payload"]?["attachments"]?[0]?["attachment_id"] == "x1")
    }

    @Test("approval is offered only for the exact pending request with a reviewable command")
    func approvalGate() throws {
        let ok = try #require(RoomPendingAction(approval()))
        #expect(ok.canAllowOnce && ok.canDeny)
        #expect(try #require(RoomPendingAction(approval(requestID: nil))).canAllowOnce == false)
        #expect(try #require(RoomPendingAction(approval(command: "", choices: ["once", "deny"]))).canAllowOnce == false)
        #expect(try #require(RoomPendingAction(approval(command: "<tool> (x)"))).canAllowOnce)
        #expect(try #require(RoomPendingAction(approval(choices: ["deny"]))).canAllowOnce == false)
        #expect(try #require(RoomPendingAction(approval(choices: ["once"]))).canDeny == false)
    }

    @Test("approve sends the exact request and choice, and refuses a stale action without a call")
    func approveCalls() async throws {
        let bots = ScriptedBots()
        bots.script("groups.approve", ["approved": true, "result": [:]])
        let service = RoomsService(gateway: bots.gateway, profile: "default")
        let action = try #require(RoomPendingAction(approval()))
        try await service.approve(roomID: "r1", action: action, allow: true)
        try await service.approve(roomID: "r1", action: action, allow: false)
        let choices = bots.calls(to: "groups.approve").compactMap { $0.params["choice"]?.stringValue }
        #expect(choices == ["once", "deny"])
        let first = try #require(bots.calls.first?.params)
        #expect(first["request_id"] == "req1" && first["task_id"] == "t1" && first["execution_generation"] == 2)
        let stale = try #require(RoomPendingAction(approval(requestID: nil)))
        await #expect(throws: RoomError.unavailable) { try await service.approve(roomID: "r1", action: stale, allow: true) }
        #expect(bots.calls(to: "groups.approve").count == 2)
    }

    @Test("stop, retry and discard address the room and task")
    func controls() async throws {
        let bots = ScriptedBots()
        bots.script("groups.stop", ["cancelled": 2])
        bots.script("groups.retry", ["retried": true])
        bots.script("groups.discard", ["discarded": true])
        let service = RoomsService(gateway: bots.gateway, profile: "default")
        #expect(try await service.stop(roomID: "r1", cancelID: "c1") == 2)
        let action = try #require(RoomPendingAction(["kind": "retry", "member_id": "a", "task_id": "t1", "execution_generation": 1]))
        try await service.retry(roomID: "r1", action: action)
        try await service.discard(roomID: "r1", action: action)
        #expect(bots.calls(to: "groups.stop").first?.params["cancel_id"] == "c1")
        #expect(bots.calls(to: "groups.retry").first?.params["task_id"] == "t1")
        #expect(bots.calls(to: "groups.discard").count == 1)
    }

    @Test("upload derives the kind from the mime and refuses oversized data before sending")
    func upload() async throws {
        let bots = ScriptedBots()
        bots.script("groups.attachment.upload", ["attachment_id": "x1", "kind": "image", "name": "p.jpg", "mime": "image/jpeg", "size": 3])
        let service = RoomsService(gateway: bots.gateway, profile: "default")
        let stored = try await service.upload(roomID: "r1", uploadID: "u1", data: Data([1, 2, 3]), name: "p.jpg", mime: "image/jpeg")
        #expect(stored.attachmentID == "x1")
        let params = try #require(bots.calls.first?.params)
        #expect(params["kind"] == "image" && params["upload_id"] == "u1" && params["data_base64"] == "AQID")
        #expect(RoomsService.kind(forMime: "application/pdf") == "pdf" && RoomsService.kind(forMime: "text/plain") == "file")
        let big = Data(count: RoomsService.maxAttachmentBytes + 1)
        await #expect(throws: RoomError.attachmentTooLarge) { try await service.upload(roomID: "r1", uploadID: "u2", data: big, name: "b", mime: "x/y") }
        #expect(bots.calls.count == 1)
    }

    @Test("download decodes the bytes and rejects a malformed answer")
    func download() async throws {
        let bots = ScriptedBots()
        bots.script("groups.attachment.download", ["data_base64": "AQID"])
        bots.script("groups.attachment.download", ["data_base64": "%%%"])
        let service = RoomsService(gateway: bots.gateway, profile: "default")
        let attachment = try #require(RoomAttachment(["attachment_id": "x1"]))
        #expect(try await service.download(roomID: "r1", eventID: "e1", attachment: attachment) == Data([1, 2, 3]))
        await #expect(throws: BotsError.invalidResponse) { try await service.download(roomID: "r1", eventID: "e1", attachment: attachment) }
        #expect(bots.calls.first?.params["event_id"] == "e1")
    }

    @Test("capabilities expose the method list and seatable profiles; an absent list offers everything")
    func capabilities() async throws {
        let bots = ScriptedBots()
        bots.script("groups.capabilities", ["driver": true, "methods": ["groups.stop"], "seatable_profiles": ["a", "b"]])
        bots.script("groups.capabilities", ["driver": true])
        let service = RoomsService(gateway: bots.gateway, profile: "default")
        let listed = try await service.capabilities()
        #expect(listed.offers("groups.stop") && !listed.offers("groups.rename"))
        #expect(listed.seatableProfiles == ["a", "b"])
        let open = try await service.capabilities()
        #expect(open.offers("groups.rename") && open.seatableProfiles == nil)
    }
}
