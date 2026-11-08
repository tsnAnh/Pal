import Foundation
import HermesChat
import HermesDesign
import HermesProtocol
import HermesRoster
import Observation

enum BubbleDelivery: Equatable {
    case sent
    case sending
    case queued
    case failed(submissionID: String)
}

struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, delivery: BubbleDelivery)
        case assistant(text: String, isStreaming: Bool)
        case tool(name: String, summary: String?, isRunning: Bool)
        case clarify(PendingPrompt)
        case approval(PendingPrompt)
    }

    let id: String
    let kind: Kind
    let separator: Date?
}

@MainActor
@Observable
final class ChatModel {
    private(set) var rows: [ChatRow] = []
    private(set) var isOffline = true
    private(set) var isRunning = false
    private(set) var hasPendingClarify = false
    private(set) var sendError: String?

    let bot: BotRow

    private let links: BotLinks
    private let roster: RosterModel
    private var link: BotLink?
    private var session: ChatSession?
    private var outbox: Outbox?
    private var transcript = Transcript()
    private var outboxEntries: [OutboxEntry] = []
    private var arrivals: [String: Date] = [:]
    private var hasBaseline = false
    private var lastSignature = ActivitySignature(running: false, prompting: false)
    private var running: Task<Void, Never>?
    private var delivering = false
    private var retried: Set<String> = []

    private struct ActivitySignature: Equatable {
        let running: Bool
        let prompting: Bool
    }

    var pendingDraft: String? { roster.drafts[bot.name] }
    var activity: BotActivity { roster.activity(for: bot.name) }
    var avatarMood: AvatarMood { roster.avatarMood(for: bot.name) }

    private static let separatorGap: TimeInterval = 10 * 60

    init(bot: BotRow, links: BotLinks, roster: RosterModel) {
        self.bot = bot
        self.links = links
        self.roster = roster
    }

    func start() {
        guard running == nil else { return }
        let link: BotLink
        do {
            link = try links.link(for: bot.name)
        } catch {
            sendError = String(localized: "Messages can't be saved on this device.")
            return
        }
        self.link = link
        outbox = link.outbox
        running = Task { await self.run(link) }
    }

    func stop() {
        running?.cancel()
        running = nil
        let session = self.session
        let link = self.link
        self.session = nil
        self.link = nil
        outbox = nil
        if let session, let link { Task { await link.sessions.release(session) } }
        roster.nudge()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let prompt = pendingClarify {
            answer(prompt, with: trimmed)
            return
        }
        guard let outbox else { return }
        Task {
            do {
                let entry = try await outbox.enqueue(botID: bot.name, text: trimmed)
                await refreshOutbox()
                _ = await outbox.deliver(entry.submissionID)
                await refreshOutbox()
            } catch {
                sendError = String(localized: "Your message could not be saved.")
            }
        }
    }

    func retry(_ submissionID: String) {
        guard let outbox, let failed = outboxEntries.first(where: { $0.submissionID == submissionID }) else { return }
        Task {
            guard let entry = try? await outbox.requeue(failed) else { return }
            retried.insert(submissionID)
            await refreshOutbox()
            _ = await outbox.deliver(entry.submissionID)
            await refreshOutbox()
        }
    }

    func answer(_ prompt: PendingPrompt, with text: String) {
        guard let session else { return }
        Task {
            do {
                try await session.answerClarify(prompt, answer: text)
            } catch {
                sendError = String(localized: "Your answer could not be sent. Try again.")
            }
        }
    }

    func answerApproval(_ prompt: PendingPrompt, choice: String) {
        guard let session else { return }
        Task { try? await session.answerApproval(prompt, choice: choice) }
    }

    func clearPendingDraft() {
        roster.drafts[bot.name] = nil
    }

    func dismissError() {
        sendError = nil
    }

    private var pendingClarify: PendingPrompt? {
        transcript.pendingPrompts.first { $0.kind == .clarify }
    }

    private func run(_ link: BotLink) async {
        let session = await link.sessions.acquire()
        guard !Task.isCancelled else {
            await link.sessions.release(session)
            return
        }
        self.session = session
        let state = await session.state
        transcript = state.transcript
        if case .live = state.phase { isOffline = false }
        async let consuming: Void = consume(session)
        async let retrying: Void = retryLoop()
        await attach(session)
        await consuming
        await retrying
    }

    private func attach(_ session: ChatSession) async {
        await refreshOutbox()
        if !outboxEntries.contains(where: { if case .failed = $0.state { true } else { false } }) {
            try? await outbox?.purgeFinished()
        }
        await refreshOutbox()
        var delay = Duration.milliseconds(500)
        while !Task.isCancelled {
            do {
                try await session.start()
                guard let settled = await session.awaitState(where: { $0.phase != .attaching }) else { return }
                if settled.phase != .detached { return }
            } catch {}
            isOffline = true
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }
    }

    private func consume(_ session: ChatSession) async {
        for await update in session.updates {
            switch update {
            case .phase(let phase):
                if case .live = phase { isOffline = false } else { isOffline = true }
            case .transcript(let next):
                transcript = next
                if case .live = await session.phase { isOffline = false }
            }
            await refreshOutbox()
            observeActivityChange()
        }
    }

    private func retryLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !isOffline, !delivering, let outbox else { continue }
            guard outboxEntries.contains(where: { $0.state == .pending }) else { continue }
            delivering = true
            _ = await outbox.deliverPending(botID: bot.name)
            delivering = false
            await refreshOutbox()
        }
    }

    private func refreshOutbox() async {
        outboxEntries = await outbox?.snapshot(botID: bot.name) ?? []
        rebuild()
    }

    private func observeActivityChange() {
        let signature = ActivitySignature(running: transcript.isRunning, prompting: pendingClarify != nil)
        defer { lastSignature = signature }
        if signature != lastSignature { roster.nudge() }
    }

    private func rebuild() {
        let items = transcript.items
        let known = Set(items.map(\.id))
        let now = Date()
        for item in items where hasBaseline && arrivals[item.id] == nil { arrivals[item.id] = now }
        var built: [ChatRow] = []
        var lastArrival: Date?
        func append(_ id: String, _ kind: ChatRow.Kind) {
            var separator: Date?
            if let arrival = arrivals[id] {
                if lastArrival.map({ arrival.timeIntervalSince($0) >= Self.separatorGap }) ?? true { separator = arrival }
                lastArrival = arrival
            }
            built.append(ChatRow(id: id, kind: kind, separator: separator))
        }
        let visible = outboxEntries.filter { !retried.contains($0.submissionID) }
        let byID = Dictionary(visible.map { ("submission:\($0.submissionID)", $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            switch item.content {
            case .user(let text, let delivery):
                var state: BubbleDelivery = switch delivery {
                case .sent: .sent
                case .sending: .sending
                case .queued: .queued
                }
                if case .failed = byID[item.id]?.state, let entry = byID[item.id] { state = .failed(submissionID: entry.submissionID) }
                append(item.id, .user(text: text, delivery: state))
            case .assistant(let text, _, let streaming):
                if text.isEmpty, !streaming { continue }
                append(item.id, .assistant(text: text, isStreaming: streaming))
            case .tool(let call):
                append(item.id, .tool(name: call.name, summary: call.summary, isRunning: call.status == .running))
            case .clarify(let card):
                append(item.id, .clarify(card.prompt))
            case .approval(let card):
                append(item.id, .approval(card.prompt))
            }
        }
        for entry in visible {
            let id = "submission:\(entry.submissionID)"
            guard !known.contains(id) else { continue }
            switch entry.state {
            case .pending: append(id, .user(text: entry.text, delivery: .queued))
            case .failed: append(id, .user(text: entry.text, delivery: .failed(submissionID: entry.submissionID)))
            case .admitted: continue
            }
        }
        rows = built
        isRunning = transcript.isRunning
        hasPendingClarify = pendingClarify != nil
        if !hasBaseline, transcript.sessionID != nil { hasBaseline = true }
    }
}
