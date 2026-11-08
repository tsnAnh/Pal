import Foundation
import HermesProtocol

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
        case clarify(PromptCard)
        case approval(PromptCard)
    }

    public var id: String
    public var content: Content
    public var deliveryFailure: String?
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

    private var segmentLengths: [Int: Int] = [:]
    private var currentSegment: Int?
    private var turnOpenings: [String: String] = [:]

    public init() {}

    public mutating func echoUser(submissionID: String, text: String) {
        let id = Self.echoID(submissionID)
        guard !items.contains(where: { $0.id == id }) else { return }
        items.append(TranscriptItem(id: id, content: .user(text: text, delivery: .sending)))
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

    public mutating func load(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionID
        items = snapshot.messages.compactMap(Self.item(from:))
        for admission in snapshot.pending where admission.status == .queued {
            guard let text = admission.text, !text.isEmpty else { continue }
            items.append(TranscriptItem(
                id: Self.echoID(admission.inputID ?? admission.admissionID),
                content: .user(text: text, delivery: .queued)
            ))
        }
        for prompt in snapshot.prompts { addCard(prompt) }
        cursor = StreamCursor(replayEpoch: snapshot.replayEpoch, lastSequence: snapshot.lastSequence)
        isRunning = snapshot.running
        executionGeneration = snapshot.executionGeneration
        resyncRequested = false
        segmentLengths = [:]
        currentSegment = nil
        turnOpenings = [:]
    }

    public func summary() -> Summary {
        Summary(items: items.compactMap { item in
            switch item.content {
            case .user(let text, _): Summary.Entry(kind: "user", text: text)
            case .assistant(let text, _, _): Summary.Entry(kind: "assistant", text: text)
            case .tool(let call): Summary.Entry(kind: "tool", text: call.name)
            case .clarify(let card): Summary.Entry(kind: "clarify", text: card.prompt.question ?? "")
            case .approval(let card): Summary.Entry(kind: "approval", text: card.prompt.command ?? "")
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
            case .clarify(let card), .approval(let card): card.prompt
            default: nil
            }
        }
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
    }

    private mutating func dropStreamingTail() {
        if let last = items.last, case .assistant(_, _, true) = last.content { items.removeLast() }
        segmentLengths = [:]
        currentSegment = nil
    }

    private static func item(from message: WireMessage) -> TranscriptItem? {
        let id = message.rowID.map { "row:\($0)" } ?? UUID().uuidString
        switch message.role {
        case "user":
            guard message.displayKind != "hidden" else { return nil }
            return TranscriptItem(id: id, content: .user(text: message.plainText, delivery: .sent))
        case "assistant":
            let text = message.plainText
            guard !text.isEmpty else { return nil }
            return TranscriptItem(id: id, content: .assistant(text: text, reasoning: message.reasoning ?? "", isStreaming: false))
        case "tool":
            let toolID = message.toolCallID ?? id
            return TranscriptItem(id: "tool:\(toolID)", content: .tool(ToolCall(
                toolID: toolID, name: message.name ?? "tool", status: .finished, summary: nil
            )))
        default:
            return nil
        }
    }

    private mutating func reduce(_ event: SessionEvent) {
        switch event {
        case .messageStart(let start):
            isRunning = true
            lastError = nil
            sealStreaming()
            confirmOldestEcho()
            _ = start
        case .messageDelta(let delta):
            appendDelta(delta)
        case .messageInterim(let interim):
            sealStreaming()
            if !interim.text.isEmpty, !hasAssistantText(interim.text) {
                items.append(TranscriptItem(
                    id: "interim:\(interim.turnID ?? "turn"):\(interim.segment ?? items.count)",
                    content: .assistant(text: interim.text, reasoning: "", isStreaming: false)
                ))
            }
            segmentLengths = [:]
            currentSegment = nil
        case .messageComplete(let complete):
            finishTurn(complete)
        case .reasoningDelta(let text):
            appendReasoning(text)
        case .toolStart(let start):
            sealStreaming()
            segmentLengths = [:]
            currentSegment = nil
            upsertTool(ToolCall(toolID: start.toolID, name: start.name, status: .running, summary: start.preview))
        case .toolComplete(let complete):
            upsertTool(ToolCall(toolID: complete.toolID, name: complete.name, status: .finished, summary: complete.summary))
        case .clarifyRequest(let prompt), .approvalRequest(let prompt):
            addCard(prompt)
        case .clarifySettled(let settled), .approvalSettled(let settled):
            items.removeAll { item in
                switch item.content {
                case .clarify(let card), .approval(let card): card.prompt.promptID == settled.promptID
                default: false
                }
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

    private mutating func materialize(_ admission: PendingAdmission) {
        guard let text = admission.text, !text.isEmpty else { return }
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
            content: .user(text: text, delivery: admission.status == .queued ? .queued : .sent)
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
        if let last = items.indices.last, case .assistant(let existing, let reasoning, true) = items[last].content {
            items[last].content = .assistant(text: existing + text, reasoning: reasoning, isStreaming: true)
        } else {
            items.append(TranscriptItem(
                id: "stream:\(delta.turnID ?? "turn"):\(segment)",
                content: .assistant(text: text, reasoning: "", isStreaming: true)
            ))
        }
    }

    private mutating func appendReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        if let last = items.indices.last, case .assistant(let existing, let reasoning, true) = items[last].content {
            items[last].content = .assistant(text: existing, reasoning: reasoning + text, isStreaming: true)
        } else {
            items.append(TranscriptItem(
                id: "stream:reasoning:\(items.count)",
                content: .assistant(text: "", reasoning: text, isStreaming: true)
            ))
        }
    }

    private mutating func finishTurn(_ complete: MessageComplete) {
        isRunning = false
        if let error = complete.error, !error.isEmpty { lastError = error }
        if let last = items.indices.last, case .assistant(let existing, let reasoning, true) = items[last].content {
            let final = complete.text.isEmpty ? existing : complete.text
            if final.isEmpty, reasoning.isEmpty {
                items.removeLast()
            } else {
                items[last].content = .assistant(text: final, reasoning: reasoning, isStreaming: false)
            }
        } else if !complete.text.isEmpty, !hasAssistantInCurrentTurn(text: complete.text) {
            items.append(TranscriptItem(
                id: "complete:\(items.count)",
                content: .assistant(text: complete.text, reasoning: "", isStreaming: false)
            ))
        }
        for index in items.indices {
            if case .tool(var call) = items[index].content, call.status == .running {
                call.status = .finished
                items[index].content = .tool(call)
            }
        }
        segmentLengths = [:]
        currentSegment = nil
    }

    private mutating func sealStreaming() {
        guard let last = items.indices.last, case .assistant(let text, let reasoning, true) = items[last].content else { return }
        if text.isEmpty, reasoning.isEmpty {
            items.removeLast()
        } else {
            items[last].content = .assistant(text: text, reasoning: reasoning, isStreaming: false)
        }
    }

    private func hasAssistantText(_ text: String) -> Bool {
        items.contains { item in
            if case .assistant(let existing, _, _) = item.content { return existing == text }
            return false
        }
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
            if case .tool(let existing) = items[index].content, merged.summary == nil { merged.summary = existing.summary }
            items[index].content = .tool(merged)
        } else {
            items.append(TranscriptItem(id: id, content: .tool(call)))
        }
    }

    private mutating func addCard(_ prompt: PendingPrompt) {
        let id = "prompt:\(prompt.promptID)"
        guard !items.contains(where: { $0.id == id }) else { return }
        let card = PromptCard(prompt: prompt)
        items.append(TranscriptItem(id: id, content: prompt.kind == .clarify ? .clarify(card) : .approval(card)))
    }
}
