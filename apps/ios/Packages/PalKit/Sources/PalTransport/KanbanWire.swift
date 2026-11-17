import Foundation
import PalProtocol

private enum Field {
    static func string(_ json: JSONValue, _ key: String) -> String? { json[key]?.stringValue }
    static func integer(_ json: JSONValue, _ key: String) -> Int? { json[key]?.intValue }
    static func list(_ json: JSONValue, _ key: String) -> [JSONValue] { json[key]?.arrayValue ?? [] }
    static func strings(_ json: JSONValue, _ key: String) -> [String] { list(json, key).compactMap(\.stringValue) }
}

public enum KanbanReadState: Sendable, Hashable {
    case present
    case ok
    case snapshotRequired
    case boardAbsent
    case boardArchived
    case cardAbsent
    case unknown(String)

    public init(wire: String?) {
        switch wire {
        case "present": self = .present
        case "ok": self = .ok
        case "snapshot_required": self = .snapshotRequired
        case "board_absent": self = .boardAbsent
        case "board_archived": self = .boardArchived
        case "card_absent": self = .cardAbsent
        default: self = .unknown(wire ?? "")
        }
    }
}

public enum KanbanCardStatus: Sendable, Hashable, Codable {
    case triage
    case todo
    case scheduled
    case ready
    case running
    case blocked
    case review
    case done
    case archived
    case unknown(String)

    public static let displayOrder: [KanbanCardStatus] = [.triage, .todo, .scheduled, .ready, .running, .blocked, .review, .done, .archived]

    public init(wire: String) {
        let key = wire.lowercased().filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
        switch key {
        case "triage": self = .triage
        case "todo": self = .todo
        case "scheduled": self = .scheduled
        case "ready": self = .ready
        case "running", "inprogress": self = .running
        case "blocked": self = .blocked
        case "review", "inreview": self = .review
        case "done", "completed": self = .done
        case "archived": self = .archived
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .triage: "triage"
        case .todo: "todo"
        case .scheduled: "scheduled"
        case .ready: "ready"
        case .running: "running"
        case .blocked: "blocked"
        case .review: "review"
        case .done: "done"
        case .archived: "archived"
        case .unknown(let raw): raw
        }
    }
}

public enum KanbanEventKind: Sendable, Hashable, Codable {
    case claimed
    case evidenceRecorded
    case outcomeVerified
    case outcomeRefused
    case prAcceptance
    case blocked
    case completed
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "claimed": self = .claimed
        case "evidence_recorded": self = .evidenceRecorded
        case "outcome_verified": self = .outcomeVerified
        case "outcome_refused": self = .outcomeRefused
        case "pr_acceptance": self = .prAcceptance
        case "blocked": self = .blocked
        case "completed": self = .completed
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .claimed: "claimed"
        case .evidenceRecorded: "evidence_recorded"
        case .outcomeVerified: "outcome_verified"
        case .outcomeRefused: "outcome_refused"
        case .prAcceptance: "pr_acceptance"
        case .blocked: "blocked"
        case .completed: "completed"
        case .unknown(let raw): raw
        }
    }
}

public enum KanbanEvidenceKind: Sendable, Hashable, Codable {
    case executionRef
    case prPublished
    case prMerged
    case artifactBuilt
    case appInstalled
    case otherResult
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "execution_ref": self = .executionRef
        case "pr_published": self = .prPublished
        case "pr_merged": self = .prMerged
        case "artifact_built": self = .artifactBuilt
        case "app_installed": self = .appInstalled
        case "other_result": self = .otherResult
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .executionRef: "execution_ref"
        case .prPublished: "pr_published"
        case .prMerged: "pr_merged"
        case .artifactBuilt: "artifact_built"
        case .appInstalled: "app_installed"
        case .otherResult: "other_result"
        case .unknown(let raw): raw
        }
    }
}

public enum KanbanContractKind: Sendable, Hashable, Codable {
    case mergedPR
    case builtArtifact
    case installedApp
    case other
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "merged_pr": self = .mergedPR
        case "built_artifact": self = .builtArtifact
        case "installed_app": self = .installedApp
        case "other": self = .other
        default: self = .unknown(wire)
        }
    }
}

public enum KanbanVerification: Sendable, Hashable, Codable {
    case independent
    case attested
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "independent": self = .independent
        case "attested": self = .attested
        default: self = .unknown(wire)
        }
    }
}

public enum KanbanOutcomeState: Sendable, Hashable, Codable {
    case verified
    case refused
    case notGoverned
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "verified": self = .verified
        case "refused": self = .refused
        case "not_governed": self = .notGoverned
        default: self = .unknown(wire)
        }
    }
}

public enum KanbanCiState: Sendable, Hashable, Codable {
    case accepted
    case rejected
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "accepted": self = .accepted
        case "rejected": self = .rejected
        default: self = .unknown(wire)
        }
    }
}

public enum KanbanProofKind: Sendable, Hashable, Codable {
    case prAcceptance
    case outcomeVerified
    case outcomeRefused
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "pr_acceptance": self = .prAcceptance
        case "outcome_verified": self = .outcomeVerified
        case "outcome_refused": self = .outcomeRefused
        default: self = .unknown(wire)
        }
    }
}

public struct KanbanScope: Sendable, Hashable, Codable {
    public let gatewayID: String
    public let board: String
    public let boardID: String

    public init(gatewayID: String, board: String, boardID: String) {
        self.gatewayID = gatewayID
        self.board = board
        self.boardID = boardID
    }

    public init?(_ json: JSONValue?) {
        guard let json, let gatewayID = Field.string(json, "gateway_id"), !gatewayID.isEmpty,
              let board = Field.string(json, "board"), !board.isEmpty
        else { return nil }
        self.gatewayID = gatewayID
        self.board = board
        boardID = Field.string(json, "board_id") ?? "\(gatewayID)/\(board)"
    }
}

public struct KanbanBoard: Sendable, Hashable, Identifiable, Codable {
    public let scope: KanbanScope
    public let name: String
    public let description: String
    public let archived: Bool
    public let dispatchMode: String
    public let projectID: String?
    public let createdAt: Int?
    public let taskCounts: [String: Int]?
    public let unavailable: String?

    public var id: String { scope.boardID }

    public init(
        scope: KanbanScope, name: String, description: String = "", archived: Bool = false, dispatchMode: String = "workers",
        projectID: String? = nil, createdAt: Int? = nil, taskCounts: [String: Int]? = nil, unavailable: String? = nil
    ) {
        self.scope = scope
        self.name = name
        self.description = description
        self.archived = archived
        self.dispatchMode = dispatchMode
        self.projectID = projectID
        self.createdAt = createdAt
        self.taskCounts = taskCounts
        self.unavailable = unavailable
    }

    public init?(_ json: JSONValue) {
        guard let scope = KanbanScope(json["scope"]) else { return nil }
        unavailable = Field.string(json, "unavailable").flatMap { $0.isEmpty ? nil : $0 }
        self.scope = scope
        let name = Field.string(json, "name") ?? ""
        self.name = name.isEmpty ? scope.board : name
        description = Field.string(json, "description") ?? ""
        archived = json["archived"]?.boolValue ?? false
        dispatchMode = Field.string(json, "dispatch_mode") ?? "workers"
        projectID = Field.string(json, "project_id").flatMap { $0.isEmpty ? nil : $0 }
        createdAt = Field.integer(json, "created_at")
        if let counts = json["task_counts"]?.objectValue {
            taskCounts = counts.compactMapValues(\.intValue)
        } else {
            taskCounts = nil
        }
    }

    public func count(of status: KanbanCardStatus) -> Int? {
        taskCounts?[status.wire]
    }
}

public struct KanbanCard: Sendable, Hashable, Identifiable, Codable {
    public let cardID: String
    public let taskID: String
    public let title: String
    public let status: KanbanCardStatus
    public let assignee: String?
    public let priority: Int?
    public let createdAt: Int?
    public let startedAt: Int?
    public let completedAt: Int?
    public let blockKind: String?
    public let governed: Bool

    public var id: String { cardID }

    public init(cardID: String, taskID: String, title: String, status: KanbanCardStatus, assignee: String? = nil, priority: Int? = nil, createdAt: Int? = nil, startedAt: Int? = nil, completedAt: Int? = nil, blockKind: String? = nil, governed: Bool = false) {
        self.cardID = cardID
        self.taskID = taskID
        self.title = title
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.blockKind = blockKind
        self.governed = governed
    }

    public init?(_ json: JSONValue) {
        guard let cardID = Field.string(json, "card_id"), !cardID.isEmpty,
              let taskID = Field.string(json, "task_id"), !taskID.isEmpty
        else { return nil }
        self.cardID = cardID
        self.taskID = taskID
        title = Field.string(json, "title") ?? ""
        status = KanbanCardStatus(wire: Field.string(json, "status") ?? "")
        assignee = Field.string(json, "assignee")
        priority = Field.integer(json, "priority")
        createdAt = Field.integer(json, "created_at")
        startedAt = Field.integer(json, "started_at")
        completedAt = Field.integer(json, "completed_at")
        blockKind = Field.string(json, "block_kind")
        governed = json["governed"]?.boolValue ?? false
    }
}

public struct KanbanPrerequisite: Sendable, Hashable, Codable {
    public let taskID: String
    public let requiresTaskID: String

    public init(taskID: String, requiresTaskID: String) {
        self.taskID = taskID
        self.requiresTaskID = requiresTaskID
    }

    public init?(_ json: JSONValue) {
        guard let taskID = Field.string(json, "task_id"), let requires = Field.string(json, "requires_task_id") else { return nil }
        self.taskID = taskID
        requiresTaskID = requires
    }
}

public struct KanbanBoardsList: Sendable, Equatable {
    public let gatewayID: String
    public let boards: [KanbanBoard]
    public let boardsSeen: Int?

    public var isVerifiedEmpty: Bool { boards.isEmpty && boardsSeen == 0 }

    public init(gatewayID: String, boards: [KanbanBoard], boardsSeen: Int? = nil) {
        self.gatewayID = gatewayID
        self.boards = boards
        self.boardsSeen = boardsSeen
    }

    public init?(_ json: JSONValue) {
        guard let gatewayID = Field.string(json, "gateway_id"), !gatewayID.isEmpty else { return nil }
        let rows = Field.list(json, "boards")
        let boards = rows.compactMap(KanbanBoard.init)
        guard boards.count == rows.count else { return nil }
        self.gatewayID = gatewayID
        self.boards = boards
        boardsSeen = Field.integer(json, "boards_seen")
    }
}

public struct KanbanSnapshotPage: Sendable, Equatable {
    public let state: KanbanReadState
    public let reason: String?
    public let scope: KanbanScope
    public let board: KanbanBoard?
    public let cards: [KanbanCard]
    public let prerequisites: [KanbanPrerequisite]
    public let nextPageToken: String?
    public let cursor: String?

    public init(state: KanbanReadState, reason: String? = nil, scope: KanbanScope, board: KanbanBoard? = nil, cards: [KanbanCard] = [], prerequisites: [KanbanPrerequisite] = [], nextPageToken: String? = nil, cursor: String? = nil) {
        self.state = state
        self.reason = reason
        self.scope = scope
        self.board = board
        self.cards = cards
        self.prerequisites = prerequisites
        self.nextPageToken = nextPageToken
        self.cursor = cursor
    }

    public init?(_ json: JSONValue) {
        guard let scope = KanbanScope(json["scope"]) else { return nil }
        self.scope = scope
        state = KanbanReadState(wire: Field.string(json, "state"))
        reason = Field.string(json, "reason")
        board = json["board"].flatMap(KanbanBoard.init)
        cards = Field.list(json, "cards").compactMap(KanbanCard.init)
        prerequisites = Field.list(json, "prerequisites").compactMap(KanbanPrerequisite.init)
        nextPageToken = Field.string(json, "next_page_token").flatMap { $0.isEmpty ? nil : $0 }
        cursor = Field.string(json, "cursor").flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct KanbanRun: Sendable, Hashable, Identifiable, Codable {
    public let runID: Int
    public let profile: String?
    public let executor: String?
    public let executorSession: String?
    public let status: String
    public let outcome: String?
    public let startedAt: Int?
    public let endedAt: Int?
    public let lastHeartbeatAt: Int?
    public let summary: String?
    public let error: String?

    public var id: Int { runID }

    public init?(_ json: JSONValue) {
        guard let runID = Field.integer(json, "run_id") else { return nil }
        self.runID = runID
        profile = Field.string(json, "profile")
        executor = Field.string(json, "executor")
        executorSession = Field.string(json, "executor_session")
        status = Field.string(json, "status") ?? ""
        outcome = Field.string(json, "outcome")
        startedAt = Field.integer(json, "started_at")
        endedAt = Field.integer(json, "ended_at")
        lastHeartbeatAt = Field.integer(json, "last_heartbeat_at")
        summary = Field.string(json, "summary")
        error = Field.string(json, "error")
    }
}

public struct KanbanExecution: Sendable, Hashable, Codable {
    public let currentRunID: Int?
    public let runs: [KanbanRun]

    public init(currentRunID: Int? = nil, runs: [KanbanRun] = []) {
        self.currentRunID = currentRunID
        self.runs = runs
    }

    init(_ json: JSONValue?) {
        currentRunID = json.flatMap { Field.integer($0, "current_run_id") }
        runs = json.map { Field.list($0, "runs").compactMap(KanbanRun.init) } ?? []
    }
}

public struct KanbanLifecycle: Sendable, Hashable, Codable {
    public let status: KanbanCardStatus
    public let assignee: String?
    public let blockKind: String?
    public let createdAt: Int?
    public let startedAt: Int?
    public let completedAt: Int?

    init(_ json: JSONValue?, fallback: KanbanCard) {
        guard let json else {
            status = fallback.status
            assignee = fallback.assignee
            blockKind = fallback.blockKind
            createdAt = fallback.createdAt
            startedAt = fallback.startedAt
            completedAt = fallback.completedAt
            return
        }
        status = KanbanCardStatus(wire: Field.string(json, "status") ?? fallback.status.wire)
        assignee = Field.string(json, "assignee")
        blockKind = Field.string(json, "block_kind")
        createdAt = Field.integer(json, "created_at")
        startedAt = Field.integer(json, "started_at")
        completedAt = Field.integer(json, "completed_at")
    }
}

public struct KanbanOutcomeContract: Sendable, Hashable, Codable {
    public let kind: KanbanContractKind
    public let repo: String?
    public let name: String?
    public let requiredFields: [String]

    init?(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else { return nil }
        kind = KanbanContractKind(wire: Field.string(json, "kind") ?? "")
        repo = Field.string(json, "repo")
        name = Field.string(json, "name")
        requiredFields = Field.strings(json, "required_fields")
    }
}

public struct KanbanCiAcceptance: Sendable, Hashable, Codable {
    public let state: KanbanCiState
    public let classification: String?
    public let runID: Int?
    public let observedAt: Int?
    public let eventID: Int?

    public static let noRecord = KanbanCiAcceptance(state: .unknown("unknown"))

    public init(state: KanbanCiState, classification: String? = nil, runID: Int? = nil, observedAt: Int? = nil, eventID: Int? = nil) {
        self.state = state
        self.classification = classification
        self.runID = runID
        self.observedAt = observedAt
        self.eventID = eventID
    }

    init(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else {
            self = .noRecord
            return
        }
        state = KanbanCiState(wire: Field.string(json, "state") ?? "unknown")
        classification = Field.string(json, "classification")
        runID = Field.integer(json, "run_id")
        observedAt = Field.integer(json, "observed_at")
        eventID = Field.integer(json, "event_id")
    }
}

public struct KanbanOutcomeVerification: Sendable, Hashable, Codable {
    public let state: KanbanOutcomeState
    public let verification: KanbanVerification?
    public let runID: Int?
    public let observedAt: Int?
    public let eventID: Int?

    public static let noRecord = KanbanOutcomeVerification(state: .unknown("unknown"), verification: nil)

    public init(state: KanbanOutcomeState, verification: KanbanVerification? = nil, runID: Int? = nil, observedAt: Int? = nil, eventID: Int? = nil) {
        self.state = state
        self.verification = verification
        self.runID = runID
        self.observedAt = observedAt
        self.eventID = eventID
    }

    init(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else {
            self = .noRecord
            return
        }
        state = KanbanOutcomeState(wire: Field.string(json, "state") ?? "unknown")
        verification = Field.string(json, "verification").map(KanbanVerification.init(wire:))
        runID = Field.integer(json, "run_id")
        observedAt = Field.integer(json, "observed_at")
        eventID = Field.integer(json, "event_id")
    }
}

public struct KanbanProofHistory: Sendable, Hashable, Codable {
    public let kind: KanbanProofKind
    public let state: String
    public let verification: KanbanVerification?
    public let runID: Int?
    public let observedAt: Int?
    public let eventID: Int?

    init(_ json: JSONValue) {
        kind = KanbanProofKind(wire: Field.string(json, "kind") ?? "")
        state = Field.string(json, "state") ?? ""
        verification = Field.string(json, "verification").map(KanbanVerification.init(wire:))
        runID = Field.integer(json, "run_id")
        observedAt = Field.integer(json, "observed_at")
        eventID = Field.integer(json, "event_id")
    }
}

public struct KanbanEvidence: Sendable, Hashable, Identifiable, Codable {
    public let evidenceID: Int
    public let runID: Int?
    public let kind: KanbanEvidenceKind
    public let producerProfile: String
    public let producerSession: String?
    public let source: String
    public let observedAt: Int?
    public let summary: String?
    public let url: URL?

    public var id: Int { evidenceID }

    private static let summaryKeys: [KanbanEvidenceKind: String] = [
        .prPublished: "pr_url", .prMerged: "pr_url", .artifactBuilt: "name",
    ]

    private static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    public init?(_ json: JSONValue) {
        guard let evidenceID = Field.integer(json, "evidence_id") else { return nil }
        self.evidenceID = evidenceID
        runID = Field.integer(json, "run_id")
        let kind = KanbanEvidenceKind(wire: Field.string(json, "kind") ?? "")
        self.kind = kind
        producerProfile = Field.string(json, "producer_profile") ?? ""
        producerSession = Field.string(json, "producer_session").flatMap { $0.isEmpty ? nil : $0 }
        source = Field.string(json, "source") ?? ""
        observedAt = Field.integer(json, "observed_at")
        summary = Self.summaryKeys[kind].flatMap { json["payload"]?[$0]?.stringValue }.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        url = kind == .prPublished || kind == .prMerged ? Self.webURL(json["payload"]?["pr_url"]?.stringValue) : nil
    }
}

public struct KanbanCardDetail: Sendable, Hashable, Codable {
    public let card: KanbanCard
    public let body: String?
    public let result: String?
    public let branchName: String?
    public let lifecycle: KanbanLifecycle
    public let execution: KanbanExecution
    public let outcomeContract: KanbanOutcomeContract?
    public let proofRunID: Int?
    public let ciAcceptance: KanbanCiAcceptance
    public let outcomeVerification: KanbanOutcomeVerification
    public let proofHistory: [KanbanProofHistory]
    public let evidence: [KanbanEvidence]
    public let prerequisites: [String]
    public let dependents: [String]

    init?(_ json: JSONValue) {
        guard let card = json["card"].flatMap(KanbanCard.init) else { return nil }
        self.card = card
        body = Field.string(json, "body")
        result = Field.string(json, "result")
        branchName = Field.string(json, "branch_name")
        lifecycle = KanbanLifecycle(json["lifecycle"], fallback: card)
        execution = KanbanExecution(json["execution"])
        outcomeContract = KanbanOutcomeContract(json["outcome_contract"])
        proofRunID = Field.integer(json, "proof_run_id")
        ciAcceptance = KanbanCiAcceptance(json["ci_acceptance"])
        outcomeVerification = KanbanOutcomeVerification(json["outcome_verification"])
        proofHistory = Field.list(json, "proof_history").map(KanbanProofHistory.init)
        evidence = Field.list(json, "evidence").compactMap(KanbanEvidence.init)
        prerequisites = Field.strings(json, "prerequisites")
        dependents = Field.strings(json, "dependents")
    }
}

public struct KanbanCardResult: Sendable, Equatable {
    public let state: KanbanReadState
    public let scope: KanbanScope
    public let detail: KanbanCardDetail?

    public init?(_ json: JSONValue) {
        guard let scope = KanbanScope(json["scope"]) else { return nil }
        self.scope = scope
        state = KanbanReadState(wire: Field.string(json, "state"))
        detail = json["detail"].flatMap(KanbanCardDetail.init)
    }
}

public struct KanbanEvidenceResult: Sendable, Equatable {
    public let state: KanbanReadState
    public let scope: KanbanScope
    public let cardID: String?
    public let evidence: [KanbanEvidence]

    public init?(_ json: JSONValue) {
        guard let scope = KanbanScope(json["scope"]) else { return nil }
        self.scope = scope
        state = KanbanReadState(wire: Field.string(json, "state"))
        cardID = Field.string(json, "card_id")
        evidence = Field.list(json, "evidence").compactMap(KanbanEvidence.init)
    }
}

public struct KanbanEvent: Sendable, Hashable, Identifiable, Codable {
    public let eventID: Int
    public let cardID: String
    public let taskID: String
    public let runID: Int?
    public let kind: KanbanEventKind
    public let createdAt: Int
    public let note: String?

    public var id: Int { eventID }

    public init(eventID: Int, cardID: String, taskID: String, runID: Int? = nil, kind: KanbanEventKind, createdAt: Int = 0, note: String? = nil) {
        self.eventID = eventID
        self.cardID = cardID
        self.taskID = taskID
        self.runID = runID
        self.kind = kind
        self.createdAt = createdAt
        self.note = note
    }

    public init?(_ json: JSONValue) {
        guard let eventID = Field.integer(json, "event_id"), let taskID = Field.string(json, "task_id"), !taskID.isEmpty else { return nil }
        self.eventID = eventID
        self.taskID = taskID
        cardID = Field.string(json, "card_id") ?? ""
        runID = Field.integer(json, "run_id")
        let kind = KanbanEventKind(wire: Field.string(json, "kind") ?? "")
        self.kind = kind
        createdAt = Field.integer(json, "created_at") ?? 0
        switch kind {
        case .blocked: note = json["data"]?["reason"]?.stringValue
        case .completed: note = json["data"]?["summary"]?.stringValue
        default: note = nil
        }
    }
}

public struct KanbanEventsPage: Sendable, Equatable {
    public let state: KanbanReadState
    public let reason: String?
    public let scope: KanbanScope
    public let events: [KanbanEvent]
    public let hasMore: Bool
    public let cursor: String?

    public init(state: KanbanReadState, reason: String? = nil, scope: KanbanScope, events: [KanbanEvent] = [], hasMore: Bool = false, cursor: String? = nil) {
        self.state = state
        self.reason = reason
        self.scope = scope
        self.events = events
        self.hasMore = hasMore
        self.cursor = cursor
    }

    public init?(_ json: JSONValue) {
        guard let scope = KanbanScope(json["scope"]) else { return nil }
        self.scope = scope
        state = KanbanReadState(wire: Field.string(json, "state"))
        reason = Field.string(json, "reason")
        events = Field.list(json, "events").compactMap(KanbanEvent.init)
        hasMore = json["has_more"]?.boolValue ?? false
        cursor = Field.string(json, "cursor").flatMap { $0.isEmpty ? nil : $0 }
    }
}
