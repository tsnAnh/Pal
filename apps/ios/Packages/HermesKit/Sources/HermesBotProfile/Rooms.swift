import Foundation
import HermesProtocol

public struct RoomMember: Sendable, Equatable, Identifiable {
    public let memberID: String
    public let profile: String
    public let handle: String
    public let displayName: String

    public var id: String { memberID }

    public init?(_ json: JSONValue) {
        guard let memberID = json["member_id"]?.stringValue, !memberID.isEmpty else { return nil }
        let profile = json["profile"]?.stringValue ?? memberID
        let handle = json["handle"]?.stringValue ?? profile
        self.memberID = memberID
        self.profile = profile
        self.handle = handle
        let name = json["display_name"]?.stringValue ?? ""
        displayName = name.isEmpty ? handle : name
    }
}

public struct Room: Sendable, Equatable, Identifiable {
    public let roomID: String
    public let name: String
    public let members: [RoomMember]
    public let authorityEpoch: Int?
    public let latestSeq: Int?
    public let updatedAt: Date?
    public let isDisbanded: Bool

    public var id: String { roomID }

    public init?(_ json: JSONValue) {
        guard let roomID = json["room_id"]?.stringValue, !roomID.isEmpty else { return nil }
        self.roomID = roomID
        name = json["name"]?.stringValue ?? ""
        members = (json["members"]?.arrayValue ?? []).compactMap(RoomMember.init)
        authorityEpoch = json["authority_epoch"]?.intValue
        latestSeq = json["latest_seq"]?.intValue
        updatedAt = json["updated_at"].flatMap(Self.seconds).map(Date.init(timeIntervalSince1970:))
        isDisbanded = json["disbanded_at"].map { $0 != .null } ?? false
    }

    static func seconds(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let number): Double(number)
        case .double(let number): number
        default: nil
        }
    }

    public func member(_ id: String?) -> RoomMember? {
        id.flatMap { id in members.first { $0.memberID == id } }
    }
}

public struct RoomAttachment: Sendable, Equatable, Identifiable {
    public let attachmentID: String
    public let kind: String
    public let name: String
    public let mime: String
    public let size: Int?

    public var id: String { attachmentID }

    public init?(_ json: JSONValue) {
        guard let attachmentID = json["attachment_id"]?.stringValue, !attachmentID.isEmpty else { return nil }
        self.attachmentID = attachmentID
        kind = json["kind"]?.stringValue ?? "file"
        name = json["name"]?.stringValue ?? "file"
        mime = json["mime"]?.stringValue ?? "application/octet-stream"
        size = json["size"]?.intValue
    }

    var payload: JSONValue {
        var object: [String: JSONValue] = [
            "attachment_id": .string(attachmentID), "kind": .string(kind), "name": .string(name), "mime": .string(mime),
        ]
        if let size { object["size"] = .int(size) }
        return .object(object)
    }
}

public enum RoomNotice: String, Sendable, Equatable {
    case turnFailed = "turn.failed"
    case turnCancelled = "turn.cancelled"
    case turnDeferred = "turn.deferred"
    case memberUnavailable = "member.unavailable"
    case stopRequested = "room.stop_requested"
    case disbanded = "room.disbanded"
    case authorityLost = "authority.lost"
}

public struct RoomEvent: Sendable, Equatable, Identifiable {
    public let seq: Int
    public let eventID: String
    public let kind: String
    public let actorKind: String
    public let actorID: String
    public let actorName: String?
    public let text: String
    public let attachments: [RoomAttachment]
    public let memberID: String?
    public let createdAt: Date?

    public var id: Int { seq }

    static let messageKinds: Set<String> = ["message", "message.user", "message.member"]

    public var isMessage: Bool { Self.messageKinds.contains(kind) }
    public var notice: RoomNotice? { RoomNotice(rawValue: kind) }
    public var isFromMember: Bool { actorKind == "member" }

    public init?(_ json: JSONValue) {
        guard let seq = json["seq"]?.intValue, let kind = json["kind"]?.stringValue else { return nil }
        let payload = json["payload"] ?? .null
        let actor = json["actor"] ?? .null
        let actorKind = actor["kind"]?.stringValue ?? ""
        let actorID = actor["id"]?.stringValue ?? ""
        self.seq = seq
        self.kind = kind
        eventID = json["event_id"]?.stringValue ?? ""
        self.actorKind = actorKind
        self.actorID = actorID
        actorName = actor["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        text = payload["text"]?.stringValue ?? payload["content"]?.stringValue ?? ""
        attachments = (payload["attachments"]?.arrayValue ?? []).compactMap(RoomAttachment.init)
        memberID = actorKind == "member" ? actorID : payload["member_id"]?.stringValue
        createdAt = json["created_at"].flatMap(Room.seconds).map(Date.init(timeIntervalSince1970:))
    }

    public func author(in room: Room) -> String? {
        guard isMessage, isFromMember else { return nil }
        return actorName ?? room.member(actorID)?.displayName ?? actorID
    }
}

public struct RoomPendingAction: Sendable, Equatable, Identifiable {
    public let kind: String
    public let memberID: String
    public let taskID: String
    public let executionGeneration: Int
    public let requestID: String?
    public let approvalRequestID: String?
    public let promptID: String?
    public let command: String
    public let description: String
    public let choices: [String]

    public var id: String { "\(kind):\(memberID):\(taskID):\(executionGeneration)" }
    public var isApproval: Bool { kind == "approval" }

    public init?(_ json: JSONValue) {
        guard let kind = json["kind"]?.stringValue,
              let memberID = json["member_id"]?.stringValue,
              let taskID = json["task_id"]?.stringValue,
              let generation = json["execution_generation"]?.intValue
        else { return nil }
        let approval = json["approval"] ?? .null
        self.kind = kind
        self.memberID = memberID
        self.taskID = taskID
        executionGeneration = generation
        requestID = json["request_id"]?.stringValue
        approvalRequestID = approval["request_id"]?.stringValue
        promptID = approval["prompt_id"]?.stringValue
        command = approval["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        description = approval["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        choices = (approval["choices"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public var shownCommand: String {
        isSyntheticLabel ? "" : command
    }

    private var isSyntheticLabel: Bool {
        command.range(of: #"^<[^>]+> \("#, options: .regularExpression) != nil
    }

    public var canAllowOnce: Bool {
        guard isApproval, let requestID, !requestID.isEmpty, choices.contains("once") else { return false }
        let matches = (approvalRequestID.map { $0 == requestID } ?? true) && (promptID.map { $0 == requestID } ?? true)
        return matches && (!shownCommand.isEmpty || (isSyntheticLabel && !description.isEmpty))
    }

    public var canDeny: Bool {
        isApproval && requestID?.isEmpty == false && choices.contains("deny")
    }
}

public struct RoomMemberActivity: Sendable, Equatable {
    public let memberID: String
    public let status: String
    public let tool: String?
}

public struct RoomDriver: Sendable, Equatable {
    public let working: Bool
    public let blocked: Bool
    public let pendingActions: [RoomPendingAction]
    public let activity: [RoomMemberActivity]

    init(_ json: JSONValue) {
        working = json["working"]?.boolValue ?? false
        blocked = json["blocked"]?.boolValue ?? false
        pendingActions = (json["pending_actions"]?.arrayValue ?? []).compactMap(RoomPendingAction.init)
        activity = (json["member_activity"]?.arrayValue ?? []).compactMap { row in
            row["member_id"]?.stringValue.map {
                RoomMemberActivity(memberID: $0, status: row["status"]?.stringValue ?? "", tool: row["tool"]?.stringValue)
            }
        }
    }

    public var busyMembers: [String] {
        activity.filter { $0.status != "queued" }.map(\.memberID)
    }

    public var isBusy: Bool { working || !activity.isEmpty }
}

public struct RoomSnapshot: Sendable, Equatable {
    public let room: Room
    public let driver: RoomDriver?
}

public struct RoomCapabilities: Sendable, Equatable {
    public let methods: Set<String>?
    public let seatableProfiles: Set<String>?
    public let driver: Bool

    public func offers(_ method: String) -> Bool { methods?.contains(method) ?? true }
}

public struct RoomLog: Sendable, Equatable {
    public private(set) var events: [RoomEvent] = []
    public private(set) var epoch: Int?

    public init() {}

    public var lastSeq: Int { events.last?.seq ?? 0 }

    public func since(for room: Room) -> Int {
        let restarted = room.authorityEpoch != epoch || (room.latestSeq.map { $0 < lastSeq } ?? false)
        return restarted ? 0 : lastSeq
    }

    public mutating func apply(room: Room, since: Int, events fresh: [RoomEvent]) {
        if since == 0 { events = [] }
        epoch = room.authorityEpoch
        let known = Set(events.map(\.seq))
        events.append(contentsOf: fresh.filter { !known.contains($0.seq) })
        events.sort { $0.seq < $1.seq }
    }
}

public enum RoomError: Error, Sendable, Equatable {
    case invalidRoster(RoomRosterProblem)
    case invalidName
    case invalidCursor
    case attachmentTooLarge
    case unavailable
}

public enum RoomRosterProblem: Sendable, Equatable {
    case groupSize
    case duplicateMember
    case notSeatable
}

public enum RoomRoster {
    public static let sizeRange = 2...6
    private static let reserved: Set<String> = ["all", "everyone"]

    public struct Seat: Sendable, Equatable {
        public let profile: String
        public let displayName: String?

        public init(profile: String, displayName: String? = nil) {
            self.profile = profile
            self.displayName = displayName
        }
    }

    public static func members(for seats: [Seat], seatable: Set<String>?) throws -> [JSONValue] {
        guard sizeRange.contains(seats.count) else { throw RoomError.invalidRoster(.groupSize) }
        var seen = reserved
        return try seats.map { seat in
            let profile = seat.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.isEmpty, seen.insert(profile.lowercased()).inserted else { throw RoomError.invalidRoster(.duplicateMember) }
            if let seatable, !seatable.contains(profile) { throw RoomError.invalidRoster(.notSeatable) }
            var entry: [String: JSONValue] = [
                "member_id": .string(profile),
                "profile": .string(profile),
                "handle": .string(profile),
                "target": ["kind": "local", "profile": .string(profile)],
            ]
            if let name = seat.displayName, !name.isEmpty { entry["display_name"] = .string(name) }
            return .object(entry)
        }
    }
}

public struct RoomsService: Sendable {
    public static let logPage = 100
    public static let maxAttachmentBytes = 15_000_000
    public static let maxNameLength = 120

    private let gateway: BotsGateway
    public let profile: String

    public init(gateway: BotsGateway, profile: String) {
        self.gateway = gateway
        self.profile = profile
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await gateway.scoped(method, profile: profile, params)
        } catch {
            throw BotsError.surface(error)
        }
    }

    public func capabilities() async throws -> RoomCapabilities {
        let result = try await call("groups.capabilities")
        return RoomCapabilities(
            methods: result["methods"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) },
            seatableProfiles: result["seatable_profiles"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) },
            driver: result["driver"]?.boolValue ?? false
        )
    }

    public func list() async throws -> [Room] {
        var rooms: [Room] = []
        var offset = 0
        while true {
            let page = try await call("groups.list", ["limit": .int(100), "offset": .int(offset)])
            rooms.append(contentsOf: (page["rooms"]?.arrayValue ?? []).compactMap(Room.init))
            guard let next = page["next_offset"]?.intValue else { break }
            guard next > offset else { throw RoomError.invalidCursor }
            offset = next
        }
        return rooms.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    public func create(roomID: String, name: String, seats: [RoomRoster.Seat], seatable: Set<String>?) async throws -> Room {
        let trimmed = try Self.validName(name)
        let members = try RoomRoster.members(for: seats, seatable: seatable)
        let result = try await call("groups.create", [
            "room_id": .string(roomID), "name": .string(trimmed), "members": .array(members),
        ])
        guard let room = result["room"].flatMap(Room.init) else { throw BotsError.invalidResponse }
        return room
    }

    public func snapshot(roomID: String) async throws -> RoomSnapshot {
        let result = try await call("groups.state", ["room_id": .string(roomID)])
        guard let room = result["room"].flatMap(Room.init) else { throw BotsError.invalidResponse }
        let driver = result["driver_status"].flatMap { $0 == .null ? nil : RoomDriver($0) }
        return RoomSnapshot(room: room, driver: driver)
    }

    public func refresh(roomID: String, log: RoomLog) async throws -> (snapshot: RoomSnapshot, since: Int, events: [RoomEvent]) {
        let snapshot = try await snapshot(roomID: roomID)
        let since = log.since(for: snapshot.room)
        var cursor = since
        var events: [RoomEvent] = []
        while true {
            let page = try await call("groups.log", [
                "room_id": .string(roomID), "since_seq": .int(cursor), "limit": .int(Self.logPage),
            ])
            let fresh = (page["events"]?.arrayValue ?? []).compactMap(RoomEvent.init)
            events.append(contentsOf: fresh)
            guard page["has_more"]?.boolValue == true else { break }
            guard let next = fresh.last?.seq, next > cursor else { throw RoomError.invalidCursor }
            cursor = next
        }
        return (snapshot, since, events)
    }

    public func send(roomID: String, eventID: String, text: String, attachments: [RoomAttachment]) async throws {
        var payload: [String: JSONValue] = ["text": .string(text), "thread_id": .string(eventID)]
        if !attachments.isEmpty { payload["attachments"] = .array(attachments.map(\.payload)) }
        _ = try await call("groups.send", [
            "room_id": .string(roomID), "event_id": .string(eventID), "payload": .object(payload),
        ])
    }

    @discardableResult
    public func stop(roomID: String, cancelID: String) async throws -> Int {
        let result = try await call("groups.stop", ["room_id": .string(roomID), "cancel_id": .string(cancelID)])
        return result["cancelled"]?.intValue ?? 0
    }

    public func rename(roomID: String, eventID: String, name: String) async throws -> Room {
        let result = try await call("groups.rename", [
            "room_id": .string(roomID), "event_id": .string(eventID), "name": .string(try Self.validName(name)),
        ])
        guard let room = result["room"].flatMap(Room.init) else { throw BotsError.invalidResponse }
        return room
    }

    public func approve(roomID: String, action: RoomPendingAction, allow: Bool) async throws {
        guard action.isApproval, let requestID = action.requestID, allow ? action.canAllowOnce : action.canDeny else {
            throw RoomError.unavailable
        }
        _ = try await call("groups.approve", [
            "room_id": .string(roomID), "member_id": .string(action.memberID), "task_id": .string(action.taskID),
            "execution_generation": .int(action.executionGeneration), "request_id": .string(requestID),
            "choice": .string(allow ? "once" : "deny"),
        ])
    }

    public func retry(roomID: String, action: RoomPendingAction) async throws {
        _ = try await call("groups.retry", Self.taskParams(roomID, action))
    }

    public func discard(roomID: String, action: RoomPendingAction) async throws {
        _ = try await call("groups.discard", Self.taskParams(roomID, action))
    }

    public func upload(roomID: String, uploadID: String, data: Data, name: String, mime: String) async throws -> RoomAttachment {
        guard data.count <= Self.maxAttachmentBytes else { throw RoomError.attachmentTooLarge }
        let result = try await call("groups.attachment.upload", [
            "room_id": .string(roomID), "upload_id": .string(uploadID), "kind": .string(Self.kind(forMime: mime)),
            "name": .string(name), "mime": .string(mime), "data_base64": .string(data.base64EncodedString()),
        ])
        guard let attachment = RoomAttachment(result) else { throw BotsError.invalidResponse }
        return attachment
    }

    public func download(roomID: String, eventID: String, attachment: RoomAttachment) async throws -> Data {
        let result = try await call("groups.attachment.download", [
            "room_id": .string(roomID), "event_id": .string(eventID), "attachment_id": .string(attachment.attachmentID),
        ])
        guard let encoded = result["data_base64"]?.stringValue, let data = Data(base64Encoded: encoded) else {
            throw BotsError.invalidResponse
        }
        return data
    }

    public static func kind(forMime mime: String) -> String {
        if mime.hasPrefix("image/") { return "image" }
        return mime == "application/pdf" ? "pdf" : "file"
    }

    static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { throw RoomError.invalidName }
        return trimmed
    }

    private static func taskParams(_ roomID: String, _ action: RoomPendingAction) -> [String: JSONValue] {
        [
            "room_id": .string(roomID), "member_id": .string(action.memberID), "task_id": .string(action.taskID),
            "execution_generation": .int(action.executionGeneration),
        ]
    }
}
