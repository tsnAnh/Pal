import Foundation
import PalProtocol

public struct StreamCursor: Sendable, Hashable {
    public var replayEpoch: String
    public var lastSequence: Int

    public init(replayEpoch: String, lastSequence: Int) {
        self.replayEpoch = replayEpoch
        self.lastSequence = lastSequence
    }
}

public struct ToolCall: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case running
        case finished
    }

    public var toolID: String
    public var name: String
    public var status: Status
    public var summary: String?
    public var prompt: String?
    public var aspectRatio: String?
    public var result: JSONValue?

    public var imageGeneration: ImageGeneration? {
        guard name == ImageGeneration.toolName else { return nil }
        return ImageGeneration.resolve(status: status, prompt: prompt, aspectRatio: aspectRatio, result: result)
    }
}

public struct PromptCard: Sendable, Hashable {
    public var prompt: PendingPrompt
}

public struct TranscriptItem: Sendable, Hashable, Identifiable {
    public enum Delivery: Sendable, Hashable {
        case sending
        case queued
        case sent
    }

    public enum Content: Sendable, Hashable {
        case user(text: String, delivery: Delivery)
        case assistant(text: String, reasoning: String, isStreaming: Bool)
        case tool(ToolCall)
        case clarifyAnswered(ClarifyRecord)
        case clarify(PromptCard)
        case botThread(BotThreadLink)
        case connection(ConnectionCard), noProvider
    }

    public var id: String
    public var uid: String?
    public var content: Content
    public var deliveryFailure: String?
    public var timestamp: Date?
    public var inbound: InboundKind = .person
    var liveSegment: LiveSegment?
    var carriesImage = false
    var receipt: TurnReceipt?

    public init(
        id: String,
        content: Content,
        deliveryFailure: String? = nil,
        timestamp: Date? = nil,
        inbound: InboundKind = .person,
        uid: String? = nil
    ) {
        self.id = id
        self.uid = uid
        self.content = content
        self.deliveryFailure = deliveryFailure
        self.timestamp = timestamp
        self.inbound = inbound
    }
}

extension TranscriptItem {
    var isAssistant: Bool {
        if case .assistant = content { return true }
        return false
    }
}

struct LiveSegment: Sendable, Hashable {
    var turnID: String
    var segment: Int
}

struct TurnReceipt: Sendable, Hashable {
    var rowIDs: Set<Int>
    var ordinal: Int
    var count: Int
}

public enum ApplyOutcome: Sendable, Hashable {
    case applied
    case duplicate
    case ignored
    case resyncRequired(ResyncReason)
}

public enum ResyncReason: Sendable, Hashable {
    case replayGap
    case epochChanged
}

public struct Transcript: Sendable, Equatable {
    public private(set) var sessionID: String?
    public private(set) var items: [TranscriptItem] = []
    public private(set) var cursor: StreamCursor?
    public private(set) var isRunning = false
    public private(set) var executionGeneration = 0
    public private(set) var resyncRequested = false
    public private(set) var lastError: String?
    public private(set) var ignoredPromptIDs: Set<String> = []

    private var segmentLengths: [Int: Int] = [:]
    private var currentSegment: Int?
    private var streamingID: String?
    private var openTurnID: String?
    private var turnOpenings: [String: String] = [:]
    private var admissionInputs: [String: String] = [:]
    private var absorbedAdmissions: Set<String> = []
    private(set) var absorbedItemIDs: Set<String> = []

    public init() {}

    static let absorbedPrefix = "absorbed:"
    static let hiddenKind = "hidden"

    public var absorbedWithoutEcho: [TranscriptItem] {
        items.filter { $0.id.hasPrefix(Self.absorbedPrefix) }
    }

    public mutating func echoUser(submissionID: String, text: String, carriesImage: Bool = false) {
        let id = Self.echoID(submissionID)
        guard !items.contains(where: { $0.id == id }) else { return }
        var item = TranscriptItem(id: id, content: .user(text: text, delivery: .sending))
        item.carriesImage = carriesImage
        items.append(item)
    }

    public mutating func apply(_ frame: SessionEventFrame) -> ApplyOutcome {
        guard let sessionID = frame.sessionID, !sessionID.isEmpty else { return .ignored }
        if let known = self.sessionID, known != sessionID { return .ignored }
        if resyncRequested { return .ignored }
        if case .replayGap = frame.event {
            requestResync()
            return .resyncRequired(.replayGap)
        }
        guard let seq = frame.seq, let epoch = frame.replayEpoch else { return .ignored }
        if let cursor {
            if cursor.replayEpoch != epoch {
                requestResync()
                return .resyncRequired(.epochChanged)
            }
            if seq <= cursor.lastSequence { return .duplicate }
        }
        cursor = StreamCursor(replayEpoch: epoch, lastSequence: seq)
        if let generation = frame.executionGeneration { executionGeneration = generation }
        reduce(frame.event)
        return .applied
    }

    public mutating func markFailed(submissionID: String, reason: String) {
        let id = Self.echoID(submissionID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deliveryFailure = reason
    }

    public mutating func requestResync() {
        resyncRequested = true
        dropStreamingTail()
    }

    public mutating func reconcile(with snapshot: SessionSnapshot) -> Bool {
        let behind = cursor.map { $0.replayEpoch != snapshot.replayEpoch || snapshot.lastSequence > $0.lastSequence } ?? true
        guard behind || resyncRequested || sessionID != snapshot.sessionID else {
            adoptLiveState(from: snapshot)
            return false
        }
        load(snapshot)
        return true
    }

    mutating func dropLiveItems(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if let streamingID, ids.contains(streamingID) { self.streamingID = nil }
        items.removeAll { ids.contains($0.id) }
    }

    public mutating func load(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionID
        items = snapshot.messages.flatMap(Self.items(from:))
        admissionInputs = [:]
        absorbedAdmissions = []
        absorbedItemIDs = []
        for admission in snapshot.pending where admission.status == .queued {
            if let inputID = admission.inputID { admissionInputs[admission.admissionID] = inputID }
            guard let text = admission.text, !text.isEmpty, admission.displayKind != Self.hiddenKind else { continue }
            items.append(TranscriptItem(
                id: Self.echoID(admission.inputID ?? admission.admissionID),
                content: .user(text: text, delivery: .queued),
                inbound: InboundKind.classify(text: text, of: admission)
            ))
        }
        for prompt in snapshot.prompts { addCard(prompt) }
        if let pending = snapshot.pendingConnection { upsertConnection(pending) }
        cursor = StreamCursor(replayEpoch: snapshot.replayEpoch, lastSequence: snapshot.lastSequence)
        isRunning = snapshot.running
        executionGeneration = snapshot.executionGeneration
        resyncRequested = false
        segmentLengths = [:]
        currentSegment = nil
        streamingID = nil
        openTurnID = nil
        turnOpenings = [:]
    }

    public func summary() -> Summary {
        Summary(items: items.compactMap { item in
            switch item.content {
            case .user(let text, _): Summary.Entry(kind: "user", text: text)
            case .assistant(let text, _, _): Summary.Entry(kind: "assistant", text: text)
            case .tool(let call): Summary.Entry(kind: "tool", text: call.name)
            case .clarifyAnswered(let record): Summary.Entry(kind: "clarify-answered", text: record.summaryText)
            case .clarify(let card): Summary.Entry(kind: "clarify", text: card.prompt.question ?? "")
            case .botThread, .noProvider: nil
            case .connection(let card): Summary.Entry(kind: "connection", text: card.operation.targets.map(\.name).joined(separator: ", "))
            }
        })
    }

    public struct Summary: Codable, Sendable, Hashable {
        public struct Entry: Codable, Sendable, Hashable {
            public var kind: String
            public var text: String
        }

        public var items: [Entry]

        public var conversation: [Entry] {
            items.filter { $0.kind == "user" || $0.kind == "assistant" }
        }
    }

    public var pendingPrompts: [PendingPrompt] {
        items.compactMap { item in
            switch item.content {
            case .clarify(let card): card.prompt
            default: nil
            }
        }
    }

    public var runningToolName: String? {
        guard isRunning else { return nil }
        for item in items.reversed() {
            if case .tool(let call) = item.content, call.status == .running { return call.name }
        }
        return nil
    }

    public var streamingText: String {
        guard let streamingIndex, case .assistant(let text, _, _) = items[streamingIndex].content else { return "" }
        return text
    }

    public func pendingConnections(now: Date = Date()) -> [ConnectionCard] {
        items.compactMap { item in
            if case .connection(let card) = item.content, card.isActionable(now: now) { return card }
            return nil
        }
    }

    public func connectionCard(opID: String) -> ConnectionCard? {
        let id = ConnectionCard.itemID(opID)
        guard let item = items.first(where: { $0.id == id }), case .connection(let card) = item.content else { return nil }
        return card
    }

    public mutating func noteConnection(_ operation: ConnectionOperation) {
        upsertConnection(operation)
    }

    public mutating func lapseConnection(opID: String) {
        let id = ConnectionCard.itemID(opID)
        guard let index = items.firstIndex(where: { $0.id == id }), case .connection(var card) = items[index].content,
              !card.lapsed
        else { return }
        card.lapsed = true
        items[index].content = .connection(card)
    }

    public var assistantTexts: [String] {
        items.compactMap { item in
            if case .assistant(let text, _, _) = item.content { return text }
            return nil
        }
    }

    static func echoID(_ submissionID: String) -> String { "submission:\(submissionID)" }

    private mutating func adoptLiveState(from snapshot: SessionSnapshot) {
        isRunning = snapshot.running
        for prompt in snapshot.prompts { addCard(prompt) }
        if let pending = snapshot.pendingConnection { upsertConnection(pending) }
        let openElsewhere = items.compactMap { item -> String? in
            guard case .connection(let card) = item.content, !card.operation.settled, !card.lapsed,
                  card.operation.opID != snapshot.pendingConnection?.opID
            else { return nil }
            return card.operation.opID
        }
        for opID in openElsewhere { lapseConnection(opID: opID) }
    }

    private mutating func dropStreamingTail() {
        if let index = streamingIndex { items.remove(at: index) }
        streamingID = nil
        segmentLengths = [:]
        currentSegment = nil
    }

    private var streamingIndex: Int? {
        guard let streamingID,
              let index = items.lastIndex(where: { $0.id == streamingID }),
              case .assistant(_, _, true) = items[index].content
        else { return nil }
        return index
    }

    private func uniqueStreamID(_ base: String) -> String {
        var candidate = base
        var ordinal = 1
        while items.contains(where: { $0.id == candidate }) {
            ordinal += 1
            candidate = "\(base)#\(ordinal)"
        }
        return candidate
    }

    private static func serverDate(_ timestamp: Double?) -> Date? {
        timestamp.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    private static func items(from message: WireMessage) -> [TranscriptItem] {
        let id = message.rowID.map { "row:\($0)" } ?? UUID().uuidString
        switch message.role {
        case "user":
            guard message.displayKind != hiddenKind else { return [] }
            let text = message.plainText
            return [TranscriptItem(
                id: id,
                content: .user(text: text, delivery: .sent),
                timestamp: serverDate(message.timestamp),
                inbound: InboundKind.classify(text: text, of: message),
                uid: message.messageUID
            )]
        case "assistant":
            let text = message.plainText
            guard !text.isEmpty else { return [] }
            return [TranscriptItem(
                id: id,
                content: .reply(text, reasoning: message.reasoning ?? "", from: message),
                timestamp: serverDate(message.timestamp),
                uid: message.messageUID
            )]
        case "tool":
            let toolID = message.toolCallID ?? id
            if message.name == nil || message.name == "clarify", let result = ClarifyResult(json: message.plainText) {
                return answeredItems(toolID: toolID, records: result.records, timestamp: serverDate(message.timestamp))
            }
            if message.name == nil || message.name == ConnectionCard.toolName,
               let operation = ConnectionOperation(toolResult: message.plainText)
            {
                return [TranscriptItem(
                    id: ConnectionCard.itemID(operation.opID),
                    content: .connection(ConnectionCard(operation: operation.closed())),
                    timestamp: serverDate(message.timestamp),
                    uid: message.messageUID
                )]
            }
            return [TranscriptItem(
                id: "tool:\(toolID)",
                content: .tool(ToolCall(toolID: toolID, name: message.name ?? "tool", status: .finished, summary: nil, result: .string(message.plainText))),
                timestamp: serverDate(message.timestamp),
                uid: message.messageUID
            )]
        default:
            return []
        }
    }

    private static func answeredItems(toolID: String, records: [ClarifyRecord], timestamp: Date? = nil) -> [TranscriptItem] {
        records.enumerated().map { index, record in
            TranscriptItem(id: "tool:\(toolID)#\(index)", content: .clarifyAnswered(record), timestamp: timestamp)
        }
    }

    private mutating func reduce(_ event: SessionEvent) {
        switch event {
        case .messageStart(let start):
            isRunning = true
            lastError = nil
            sealStreaming()
            confirmOldestEcho()
            openTurnID = start.turnID
        case .messageDelta(let delta):
            appendDelta(delta)
        case .messageInterim(let interim):
            sealInterim(interim, sealed: sealStreaming())
            segmentLengths = [:]
            currentSegment = nil
        case .messageComplete(let complete):
            finishTurn(complete)
        case .inputAbsorbed(let absorbed):
            absorb(absorbed)
        case .reasoningDelta(let text):
            appendReasoning(text)
        case .toolStart(let start):
            sealStreaming()
            segmentLengths = [:]
            currentSegment = nil
            upsertTool(ToolCall(
                toolID: start.toolID,
                name: start.name,
                status: .running,
                summary: start.preview,
                prompt: start.args?["prompt"]?.stringValue,
                aspectRatio: start.args?["aspect_ratio"]?.stringValue
            ))
        case .toolComplete(let complete):
            if complete.name == "clarify", let result = ClarifyResult(json: complete.result ?? complete.resultText) {
                recordAnswers(toolID: complete.toolID, records: result.records)
            } else {
                upsertTool(ToolCall(
                    toolID: complete.toolID,
                    name: complete.name,
                    status: .finished,
                    summary: complete.summary,
                    prompt: complete.args?["prompt"]?.stringValue,
                    aspectRatio: complete.args?["aspect_ratio"]?.stringValue,
                    result: complete.resultValue ?? complete.resultText.map(JSONValue.string)
                ))
            }
            if complete.name == ConnectionCard.toolName, let operation = Self.connectionOperation(of: complete) {
                upsertConnection(operation.closed())
            }
        case .connectionRequest(let operation), .connectionUpdate(let operation):
            upsertConnection(operation)
        case .clarifyRequest(let prompt), .approvalRequest(let prompt):
            addCard(prompt)
        case .clarifySettled(let settled), .approvalSettled(let settled):
            items.removeAll { item in
                if case .clarify(let card) = item.content { card.prompt.promptID == settled.promptID } else { false }
            }
        case .sessionInfo(let info):
            if let running = info.running { isRunning = running }
            for admission in info.pending ?? [] { materialize(admission) }
        case .error(let message):
            lastError = message
        case .replayGap, .unknown:
            break
        }
    }

    private mutating func absorb(_ event: InputAbsorbed) {
        let fresh = event.admissionIDs.filter { !absorbedAdmissions.contains($0) }
        guard event.admissionIDs.isEmpty || !fresh.isEmpty else { return }
        sealStreaming()
        segmentLengths = [:]
        currentSegment = nil
        var echoes = fresh.compactMap(echoIndex(forAdmission:))
        var remainder = echoes.reduce(event.text) { Self.removing(userText(at: $1), from: $0) }
        if !Self.isBlank(remainder) {
            let unsent = items.indices.filter { !echoes.contains($0) && isUnsentEcho(at: $0) }
            var trial = remainder
            let taken = unsent.filter { index in
                guard let range = trial.range(of: userText(at: index)), !userText(at: index).isEmpty else { return false }
                trial.removeSubrange(range)
                return true
            }
            if !taken.isEmpty, Self.isBlank(trial) {
                echoes += taken
                remainder = ""
            }
        }
        let placed = echoes.sorted().map { items[$0] }
        for index in echoes.sorted(by: >) { items.remove(at: index) }
        for var item in placed {
            item.content = .user(text: userText(of: item), delivery: .sent)
            item.uid = event.messageUID ?? item.uid
            items.append(item)
            absorbedItemIDs.insert(item.id)
        }
        if !Self.isBlank(remainder) {
            let text = placed.isEmpty ? event.text : remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "\(Self.absorbedPrefix)\(fresh.first ?? event.messageUID ?? String(items.count))"
            items.append(TranscriptItem(
                id: id,
                content: .user(text: text, delivery: .sent),
                inbound: InboundKind.classify(text: text, of: event),
                uid: event.messageUID
            ))
            absorbedItemIDs.insert(id)
        }
        absorbedAdmissions.formUnion(fresh)
    }

    private func echoIndex(forAdmission admissionID: String) -> Int? {
        let ids = Set([admissionInputs[admissionID].map(Self.echoID), Self.echoID(admissionID)].compactMap { $0 })
        return items.firstIndex { ids.contains($0.id) && $0.isUser }
    }

    private func isUnsentEcho(at index: Int) -> Bool {
        guard case .user(_, let delivery) = items[index].content else { return false }
        return delivery != .sent && items[index].deliveryFailure == nil
    }

    private func userText(at index: Int) -> String { userText(of: items[index]) }

    private func userText(of item: TranscriptItem) -> String {
        if case .user(let text, _) = item.content { text } else { "" }
    }

    private static func removing(_ text: String, from source: String) -> String {
        guard !text.isEmpty, let range = source.range(of: text) else { return source }
        var result = source
        result.removeSubrange(range)
        return result
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private mutating func materialize(_ admission: PendingAdmission) {
        if let inputID = admission.inputID { admissionInputs[admission.admissionID] = inputID }
        guard !absorbedAdmissions.contains(admission.admissionID) else { return }
        guard let text = admission.text, !text.isEmpty, admission.displayKind != Self.hiddenKind else { return }
        let id = Self.echoID(admission.inputID ?? admission.admissionID)
        if let index = items.firstIndex(where: { $0.id == id }) {
            if admission.status != .queued, case .user(let existing, _) = items[index].content {
                items[index].content = .user(text: existing, delivery: .sent)
            }
            return
        }
        if admission.status != .queued, lastUserTurnIsUnanswered(text: text) { return }
        items.append(TranscriptItem(
            id: id,
            content: .user(text: text, delivery: admission.status == .queued ? .queued : .sent),
            inbound: InboundKind.classify(text: text, of: admission)
        ))
    }

    private func lastUserTurnIsUnanswered(text: String) -> Bool {
        for item in items.reversed() {
            switch item.content {
            case .assistant(_, _, let streaming): if !streaming { return false }
            case .user(let existing, _): return existing == text
            default: continue
            }
        }
        return false
    }

    private mutating func confirmOldestEcho() {
        guard let index = items.firstIndex(where: { item in
            if case .user(_, let delivery) = item.content { return delivery != .sent && item.deliveryFailure == nil }
            return false
        }), case .user(let text, _) = items[index].content else { return }
        items[index].content = .user(text: text, delivery: .sent)
        turnOpenings[items[index].id] = items.last?.id
    }

    func turnOutputStart(after echoID: String, anchoredAt index: Int) -> Int {
        guard let preceding = turnOpenings[echoID],
              let position = items.firstIndex(where: { $0.id == preceding })
        else { return index + 1 }
        return max(position + 1, index + 1)
    }

    private mutating func appendDelta(_ delta: MessageDelta) {
        guard let text = delta.text, !text.isEmpty else { return }
        let segment = delta.segment ?? currentSegment ?? 0
        if currentSegment != segment {
            sealStreaming()
            currentSegment = segment
        }
        let applied = segmentLengths[segment] ?? 0
        if let offset = delta.offset, offset < applied { return }
        segmentLengths[segment] = applied + text.utf16.count
        if let index = streamingIndex, case .assistant(let existing, let reasoning, true) = items[index].content {
            items[index].content = .assistant(text: existing + text, reasoning: reasoning, isStreaming: true)
        } else {
            let id = uniqueStreamID("stream:\(delta.turnID ?? "turn"):\(segment)")
            var item = TranscriptItem(id: id, content: .assistant(text: text, reasoning: "", isStreaming: true))
            if let turnID = delta.turnID { item.liveSegment = LiveSegment(turnID: turnID, segment: segment) }
            items.append(item)
            streamingID = id
        }
    }

    private mutating func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        if let index = streamingIndex, case .assistant(let existing, let reasoning, true) = items[index].content {
            items[index].content = .assistant(text: existing, reasoning: reasoning + text, isStreaming: true)
        } else {
            let id = uniqueStreamID("stream:reasoning:\(items.count)")
            items.append(TranscriptItem(id: id, content: .assistant(text: "", reasoning: text, isStreaming: true)))
            streamingID = id
        }
    }

    private mutating func finishTurn(_ complete: MessageComplete) {
        isRunning = false
        if let error = complete.error, !error.isEmpty { lastError = error }
        var finalID: String?
        if let index = streamingIndex, case .assistant(let existing, let reasoning, true) = items[index].content {
            let final = complete.text.isEmpty ? existing : complete.text
            if final.isEmpty, reasoning.isEmpty, !complete.needsModelProvider {
                items.remove(at: index)
            } else {
                items[index].content = complete.needsModelProvider ? .noProvider : .assistant(text: final, reasoning: reasoning, isStreaming: false)
                items[index].uid = complete.identity.messageUID ?? items[index].uid
                finalID = items[index].id
            }
        } else if complete.needsModelProvider ? items.last?.content != .noProvider : !complete.text.isEmpty && !hasAssistantInCurrentTurn(text: complete.text) {
            var item = TranscriptItem(
                id: "complete:\(complete.identity.messageUID ?? String(items.count))",
                content: complete.needsModelProvider ? .noProvider : .assistant(text: complete.text, reasoning: "", isStreaming: false),
                uid: complete.identity.messageUID
            )
            if let turnID = complete.identity.turnID, let segment = complete.identity.segment {
                item.liveSegment = LiveSegment(turnID: turnID, segment: segment)
            }
            items.append(item)
            finalID = item.id
        }
        stampReceipt(turnID: complete.identity.turnID ?? openTurnID, rowIDs: complete.identity.rowIDs, finalID: finalID)
        for index in items.indices {
            if case .tool(var call) = items[index].content, call.status == .running {
                call.status = .finished
                items[index].content = .tool(call)
            }
        }
        streamingID = nil
        segmentLengths = [:]
        currentSegment = nil
        openTurnID = nil
    }

    private mutating func stampReceipt(turnID: String?, rowIDs: [Int], finalID: String?) {
        guard let turnID, !rowIDs.isEmpty else { return }
        let spoken = items.indices.filter { index in
            let item = items[index]
            guard item.liveSegment?.turnID == turnID || item.id == finalID,
                  case .assistant(let text, _, false) = item.content else { return false }
            return !Self.isBlank(text) && !TranscriptVisibility.isHidden(item)
        }
        let rows = Set(rowIDs)
        for (ordinal, index) in spoken.enumerated() {
            items[index].receipt = TurnReceipt(rowIDs: rows, ordinal: ordinal, count: spoken.count)
        }
    }

    @discardableResult
    private mutating func sealStreaming() -> String? {
        defer { streamingID = nil }
        guard let index = streamingIndex, case .assistant(let text, let reasoning, true) = items[index].content else { return nil }
        if text.isEmpty, reasoning.isEmpty {
            items.remove(at: index)
            return nil
        }
        items[index].content = .assistant(text: text, reasoning: reasoning, isStreaming: false)
        return items[index].id
    }

    private mutating func sealInterim(_ interim: MessageInterim, sealed: String?) {
        let segment = interim.turnID.flatMap { turnID in interim.segment.map { LiveSegment(turnID: turnID, segment: $0) } }
        let owner = segment.flatMap { segment in items.lastIndex { $0.liveSegment == segment && $0.isAssistant } }
            ?? sealed.flatMap { id in items.firstIndex { $0.id == id } }
        if let owner {
            if !interim.text.isEmpty, case .assistant(_, let reasoning, _) = items[owner].content {
                items[owner].content = .assistant(text: interim.text, reasoning: reasoning, isStreaming: false)
            }
            return
        }
        guard !interim.text.isEmpty, !hasAssistantText(interim.text) else { return }
        var item = TranscriptItem(
            id: "interim:\(interim.turnID ?? "turn"):\(interim.segment ?? items.count)",
            content: .assistant(text: interim.text, reasoning: "", isStreaming: false)
        )
        item.liveSegment = segment
        items.append(item)
    }

    private func hasAssistantText(_ text: String) -> Bool {
        items.contains { item in
            if case .assistant(let existing, _, _) = item.content { return Self.sameBody(existing, text) }
            return false
        }
    }

    static func sameBody(_ a: String, _ b: String) -> Bool {
        a == b || a.trimmingCharacters(in: .whitespacesAndNewlines) == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasAssistantInCurrentTurn(text: String) -> Bool {
        for item in items.reversed() {
            switch item.content {
            case .assistant(let existing, _, _): if existing == text { return true }
            case .user(_, let delivery): if delivery == .sent { return false }
            default: continue
            }
        }
        return false
    }

    private mutating func upsertTool(_ call: ToolCall) {
        let id = "tool:\(call.toolID)"
        if let index = items.firstIndex(where: { $0.id == id }) {
            var merged = call
            if case .tool(let existing) = items[index].content {
                if merged.summary == nil { merged.summary = existing.summary }
                if merged.prompt == nil { merged.prompt = existing.prompt }
                if merged.aspectRatio == nil { merged.aspectRatio = existing.aspectRatio }
            }
            items[index].content = .tool(merged)
        } else {
            items.append(TranscriptItem(id: id, content: .tool(call)))
        }
    }

    private mutating func recordAnswers(toolID: String, records: [ClarifyRecord]) {
        let answered = Self.answeredItems(toolID: toolID, records: records)
        guard !items.contains(where: { $0.id == answered.first?.id }) else { return }
        if let index = items.firstIndex(where: { $0.id == "tool:\(toolID)" }) {
            items.replaceSubrange(index...index, with: answered)
        } else {
            items.append(contentsOf: answered)
        }
    }

    private static func connectionOperation(of complete: ToolComplete) -> ConnectionOperation? {
        if let operation = ConnectionOperation(toolResult: complete.result ?? complete.resultText) { return operation }
        return complete.resultValue.flatMap { ConnectionOperation(value: $0) }
    }

    private mutating func upsertConnection(_ operation: ConnectionOperation) {
        if let owner = operation.ownerSessionID, let sessionID, owner != sessionID { return }
        let id = ConnectionCard.itemID(operation.opID)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            items.append(TranscriptItem(id: id, content: .connection(ConnectionCard(operation: operation))))
            return
        }
        guard case .connection(var card) = items[index].content, operation.seq > card.operation.seq else { return }
        card.operation = operation
        items[index].content = .connection(card)
    }

    mutating func addCard(_ prompt: PendingPrompt) {
        let id = "prompt:\(prompt.promptID)"
        guard !items.contains(where: { $0.id == id }) else { return }
        switch prompt.kind {
        case .clarify:
            items.append(TranscriptItem(id: id, content: .clarify(PromptCard(prompt: prompt))))
        case .approval:
            guard let form = prompt.ownerForm() else {
                ignoredPromptIDs.insert(prompt.promptID)
                return
            }
            items.append(TranscriptItem(id: id, content: .clarify(PromptCard(prompt: form))))
        }
    }
}
