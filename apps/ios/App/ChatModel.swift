import Foundation
import HermesChat
import HermesDesign
import HermesDiagnostics
import HermesProtocol
import HermesRoster
import Observation

enum BubbleDelivery: Equatable {
    case sent
    case sending
    case waitingForConnection
    case failed(submissionID: String)
}

enum ChatNotice: Equatable {
    case botMessage(senderName: String, body: String)
    case notification
    case backgroundTaskFinished
}

struct ReplyTarget: Equatable {
    enum Author: Equatable {
        case you
        case bot
    }

    let rowID: String
    let author: Author
    let quote: String
}

struct ChatRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, delivery: BubbleDelivery)
        case assistant(text: String)
        case working(status: String?)
        case clarifyAnswered(question: String, answer: ClarifyRecord.Answer)
        case clarify(PendingPrompt)
        case approval(PendingPrompt)
        case notice(ChatNotice)
        case botThread(BotThreadLink)
    }

    let id: String
    let kind: Kind
    let separator: Date?
    let showsUnreadDivider: Bool

    var searchableText: String? {
        switch kind {
        case .user(let text, _), .assistant(let text): text
        case .notice(.botMessage(_, let body)): body
        default: nil
        }
    }
}

enum ChatConnectionState: Equatable {
    case connecting
    case live
    case reconnecting
}

struct VoiceReply: Equatable {
    var text: String
    var isComplete: Bool
    var turn: Int
}

struct PendingAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case file
    }

    enum Staged: Equatable {
        case image(PromptAttachment)
        case file(referenceText: String)
    }

    enum State: Equatable {
        case uploading
        case ready(Staged)
        case failed
    }

    let id = UUID()
    let kind: Kind
    let name: String
    let thumbnail: Data?
    var state: State
}

@MainActor
@Observable
final class ChatModel {
    private(set) var rows: [ChatRow] = []
    private(set) var connection: ChatConnectionState = .connecting
    private(set) var isRunning = false
    private(set) var hasPendingClarify = false
    private(set) var sendError: String?
    private(set) var attachments: [PendingAttachment] = []
    private(set) var slashItems: [SlashItem] = []
    private(set) var reactions: [String: String] = [:]
    private(set) var replyTarget: ReplyTarget?
    var isFinding = false
    var findQuery = "" {
        didSet { recomputeFind(resetPosition: true) }
    }
    private(set) var findMatches: [String] = []
    private(set) var findPosition = 0

    private let openedBot: BotRow
    var bot: BotRow { roster.bot(named: openedBot.name) ?? openedBot }

    private let links: BotLinks
    private let roster: RosterModel
    private let lastSeenStore: ChatLastSeenStore
    private let lastSeenAtOpen: Date?
    private var link: BotLink?
    private var session: ChatSession?
    private var outbox: Outbox?
    private var transcript = Transcript()
    private var outboxEntries: [OutboxEntry] = []
    private var botThreadLinks: [BotThreadLink] = []
    private var arrivals: [String: Date] = [:]
    private var hasBaseline = false
    private var hasBeenLive = false
    private var lastSignature = ActivitySignature(running: false, prompting: false)
    private var running: Task<Void, Never>?
    private var delivering = false
    private var retried: Set<String> = []
    private var absorbedEchoes = AbsorbedEchoLedger()
    private var hasHydrated = false
    private var cachedItems: [TranscriptItem] = []
    private var lastCached: CachedTranscript?
    private var pendingCacheSave: Task<Void, Never>?

    private struct ActivitySignature: Equatable {
        let running: Bool
        let prompting: Bool
    }

    var pendingDraft: String? { roster.drafts[bot.name] }
    var isOffline: Bool { connection != .live }
    var chatAccent: BotAccent? { bot.usesPrimaryLook ? nil : bot.accent }
    var avatars: ParticipantAvatars { ParticipantAvatars(roster: roster) }
    var activity: BotActivity { roster.activity(for: bot.name) }
    var avatarMood: AvatarMood { roster.avatarMood(for: bot.name) }

    var isCatchingUp: Bool {
        switch connection {
        case .connecting: true
        case .reconnecting, .live: false
        }
    }

    var canSendAttachments: Bool {
        !attachments.contains { $0.state == .uploading }
    }

    var currentFindRowID: String? {
        findMatches.indices.contains(findPosition) ? findMatches[findPosition] : nil
    }

    var voiceTurn: Int {
        transcript.items.count { item in
            if case .user = item.content { item.inbound.isPerson } else { false }
        }
    }

    var voiceReply: VoiceReply {
        var parts: [String] = []
        for item in transcript.items.reversed() {
            switch item.content {
            case .user where item.inbound.isPerson:
                break
            case .assistant(let text, _, _) where !text.isEmpty:
                parts.append(text)
                continue
            default:
                continue
            }
            break
        }
        return VoiceReply(text: parts.reversed().joined(separator: "\n\n"), isComplete: !transcript.isRunning, turn: voiceTurn)
    }

    init(bot: BotRow, links: BotLinks, roster: RosterModel, lastSeenStore: ChatLastSeenStore = ChatLastSeenStore()) {
        openedBot = bot
        self.links = links
        self.roster = roster
        self.lastSeenStore = lastSeenStore
        lastSeenAtOpen = lastSeenStore.lastSeen(for: bot.name)
    }

    private func hydrateFromCache() {
        guard !hasHydrated else { return }
        hasHydrated = true
        guard transcript.sessionID == nil, let cached = roster.conversationCache.load(bot: openedBot.name) else { return }
        lastCached = cached
        cachedItems = cached.transcriptItems
        rebuild()
        LaunchClock.mark("chat \(openedBot.name) shown from cache (\(cachedItems.count) items)", on: .osLog())
    }

    func start() {
        hydrateFromCache()
        roster.markRead(bot.name)
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
        markViewed()
        saveCache()
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

    func markViewed() {
        saveCache()
        guard hasBaseline else { return }
        lastSeenStore.record(Date(), for: bot.name)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = attachments.compactMap { attachment -> PendingAttachment.Staged? in
            if case .ready(let staged) = attachment.state { staged } else { nil }
        }
        guard !trimmed.isEmpty || !staged.isEmpty, canSendAttachments else { return }
        if let prompt = pendingClarify, staged.isEmpty {
            answer(prompt, with: trimmed)
            return
        }
        guard let outbox else { return }
        var body = trimmed
        if let replyTarget, !body.isEmpty {
            body = Self.quoted(replyTarget.quote) + "\n\n" + body
        }
        replyTarget = nil
        var images: [PromptAttachment] = []
        for item in staged {
            switch item {
            case .image(let attachment): images.append(attachment)
            case .file(let reference): body = body.isEmpty ? reference : body + "\n" + reference
            }
        }
        attachments.removeAll()
        Task {
            do {
                let entry = try await outbox.enqueue(botID: bot.name, text: body, attachments: images)
                await refreshOutbox()
                _ = await outbox.deliver(entry.submissionID)
                await refreshOutbox()
            } catch {
                sendError = String(localized: "Your message could not be saved.")
            }
        }
    }

    func beginReply(to rowID: String) {
        guard let row = rows.first(where: { $0.id == rowID }), let text = row.searchableText else { return }
        let author: ReplyTarget.Author = if case .user = row.kind { .you } else { .bot }
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        replyTarget = ReplyTarget(rowID: rowID, author: author, quote: String(flattened.prefix(Self.quoteLimit)))
    }

    func cancelReply() {
        replyTarget = nil
    }

    func canReact(to rowID: String) -> Bool {
        reactionTarget(for: rowID) != nil
    }

    func react(to rowID: String, with emoji: String) {
        guard let session, let target = reactionTarget(for: rowID) else { return }
        let previous = reactions[rowID]
        let outgoing: String? = previous == emoji ? nil : emoji
        reactions[rowID] = outgoing
        Task {
            do {
                reactions[rowID] = try await session.react(to: target, emoji: outgoing)
            } catch {
                reactions[rowID] = previous
                sendError = String(localized: "Your reaction could not be sent. Try again.")
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

    func submitVoice(_ text: String) async -> Bool {
        guard let session else { return false }
        do {
            try await session.submitVoiceTurn(text)
            return true
        } catch {
            sendError = String(localized: "Your message could not be sent. Try again.")
            return false
        }
    }

    func clearPendingDraft() {
        roster.drafts[bot.name] = nil
    }

    func dismissError() {
        sendError = nil
    }

    func attachPhoto(_ upload: PreparedUpload) {
        stage(PendingAttachment(kind: .image, name: upload.filename, thumbnail: upload.thumbnail, state: .uploading)) { session in
            let staged = try await session.attachImage(upload.data, filename: upload.filename)
            return .image(staged.promptAttachment)
        }
    }

    func attachFile(_ upload: PreparedUpload, mime: String) {
        stage(PendingAttachment(kind: .file, name: upload.filename, thumbnail: nil, state: .uploading)) { session in
            let staged = try await session.attachFile(upload.data, name: upload.filename, mime: mime)
            return .file(referenceText: staged.refText)
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func reportAttachmentFailure(_ message: String) {
        sendError = message
    }

    func beginFinding() {
        isFinding = true
    }

    func endFinding() {
        isFinding = false
        findQuery = ""
    }

    func findNext() {
        guard !findMatches.isEmpty else { return }
        findPosition = (findPosition + 1) % findMatches.count
    }

    func findPrevious() {
        guard !findMatches.isEmpty else { return }
        findPosition = (findPosition - 1 + findMatches.count) % findMatches.count
    }

    /// Fetches the `/` picker's commands and skills once per chat; a failed fetch retries on the next `/`.
    func loadSlashItems() {
        guard slashItems.isEmpty, let session else { return }
        Task {
            if let items = try? await session.slashCommands() { slashItems = items }
        }
    }

    private func stage(
        _ attachment: PendingAttachment,
        upload: @escaping @Sendable (ChatSession) async throws -> PendingAttachment.Staged
    ) {
        attachments.append(attachment)
        let id = attachment.id
        guard let session else {
            update(id, to: .failed)
            sendError = String(localized: "Attachments need a connection. Try again in a moment.")
            return
        }
        Task {
            do {
                update(id, to: .ready(try await upload(session)))
            } catch {
                update(id, to: .failed)
                sendError = String(localized: "That attachment could not be uploaded.")
            }
        }
    }

    private func update(_ id: UUID, to state: PendingAttachment.State) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    private static let quoteLimit = 160

    private static func quoted(_ text: String) -> String {
        "> " + text
    }

    private func reactionTarget(for rowID: String) -> ReactionTarget? {
        guard let row = rows.first(where: { $0.id == rowID }) else { return nil }
        let role: String
        switch row.kind {
        case .user: role = "user"
        case .assistant: role = "assistant"
        default: return nil
        }
        if rowID.hasPrefix("row:"), let id = Int(rowID.dropFirst(4)) { return .row(id) }
        let newest = rows.last { candidate in
            switch candidate.kind {
            case .user: role == "user"
            case .assistant: role == "assistant"
            default: false
            }
        }
        return newest?.id == rowID ? .newest(role: role) : nil
    }

    private var runningToolName: String? {
        guard transcript.isRunning else { return nil }
        for item in transcript.items.reversed() {
            if case .tool(let call) = item.content, call.status == .running { return call.name }
        }
        return nil
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
        if case .live = state.phase { noteLive() }
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
        let intro = roster.takeIntro(for: bot.name)
        while !Task.isCancelled {
            do {
                try await session.start(intro: intro)
                guard let settled = await session.awaitState(where: { $0.phase != .attaching }) else { return }
                if settled.phase != .detached { return }
            } catch {}
            noteDisconnected()
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }
    }

    private func noteDisconnected() {
        connection = hasBeenLive ? .reconnecting : .connecting
    }

    private func noteLive() {
        if !hasBeenLive { LaunchClock.mark("chat \(openedBot.name) live", on: .osLog()) }
        hasBeenLive = true
        connection = .live
    }

    private func consume(_ session: ChatSession) async {
        for await update in session.updates {
            switch update {
            case .phase(let phase):
                if case .live = phase { noteLive() } else { noteDisconnected() }
            case .transcript(let next):
                transcript = next
                scheduleCacheSave()
                if case .live = await session.phase { noteLive() }
            case .botThreadLinks(let links):
                botThreadLinks = links
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

    private func scheduleCacheSave() {
        guard transcript.sessionID != nil, pendingCacheSave == nil else { return }
        pendingCacheSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveCache()
        }
    }

    private func saveCache() {
        pendingCacheSave?.cancel()
        pendingCacheSave = nil
        guard let snapshot = CachedTranscript(sessionID: transcript.sessionID, items: transcript.items, date: effectiveDate),
              snapshot != lastCached
        else { return }
        lastCached = snapshot
        roster.conversationCache.save(snapshot, bot: openedBot.name)
    }

    private var displayedItems: [TranscriptItem] {
        transcript.sessionID == nil && !cachedItems.isEmpty ? cachedItems : transcript.items
    }

    private func effectiveDate(_ item: TranscriptItem) -> Date? {
        item.timestamp ?? arrivals[item.id]
    }

    private func allItems() -> [TranscriptItem] {
        var items = BotThreadFolding.fold(displayedItems, links: botThreadLinks)
        let known = Set(items.map(\.id))
        let awaiting = outboxEntries.filter { entry in
            entry.state == .pending && !retried.contains(entry.submissionID) && !known.contains("submission:\(entry.submissionID)")
        }
        let absorbed = absorbedEchoes.hiddenSubmissions(
            pending: awaiting.map { AbsorbedEchoLedger.Pending(submissionID: $0.submissionID, text: displayText(for: $0)) },
            absorbed: transcript.absorbedWithoutEcho
        )
        for entry in outboxEntries where !retried.contains(entry.submissionID) {
            let id = "submission:\(entry.submissionID)"
            guard !known.contains(id), !absorbed.contains(entry.submissionID) else { continue }
            if case .admitted = entry.state { continue }
            var item = TranscriptItem(id: id, content: .user(text: displayText(for: entry), delivery: .sending), timestamp: entry.createdAt)
            if case .failed(let reason) = entry.state { item.deliveryFailure = reason }
            items.append(item)
        }
        return items
    }

    private func displayText(for entry: OutboxEntry) -> String {
        if !entry.text.isEmpty { return entry.text }
        if !entry.files.isEmpty { return entry.files.map(\.name).joined(separator: ", ") }
        return entry.attachments.isEmpty ? "" : String(localized: "Photo")
    }

    private func rebuild() {
        let now = Date()
        for item in transcript.items where hasBaseline && item.timestamp == nil && arrivals[item.id] == nil { arrivals[item.id] = now }
        let items = allItems().filter { item in
            if case .tool = item.content { return false }
            return true
        }
        let entries = ChatTimeline.entries(items: items, date: effectiveDate, lastSeen: lastSeenAtOpen)
        let visible = outboxEntries.filter { !retried.contains($0.submissionID) }
        let byID = Dictionary(visible.map { ("submission:\($0.submissionID)", $0) }, uniquingKeysWith: { first, _ in first })
        var built: [ChatRow] = []
        for entry in entries {
            guard let kind = rowKind(for: entry.item, outbox: byID[entry.item.id]) else { continue }
            built.append(ChatRow(id: entry.item.id, kind: kind, separator: entry.separator, showsUnreadDivider: entry.showsNewDivider))
        }
        if shouldShowThinking {
            built.append(ChatRow(id: Self.thinkingRowID, kind: .working(status: runningToolName.map(ToolActivity.label(for:))), separator: nil, showsUnreadDivider: false))
        }
        rows = built
        isRunning = transcript.isRunning
        hasPendingClarify = pendingClarify != nil
        if !hasBaseline, transcript.sessionID != nil { hasBaseline = true }
        recomputeFind(resetPosition: false)
    }

    private func rowKind(for item: TranscriptItem, outbox entry: OutboxEntry?) -> ChatRow.Kind? {
        switch item.content {
        case .user(let text, let delivery):
            switch item.inbound {
            case .person:
                var state: BubbleDelivery = switch delivery {
                case .sent, .queued: .sent
                case .sending: isOffline ? .waitingForConnection : .sending
                }
                if let entry, case .failed = entry.state { state = .failed(submissionID: entry.submissionID) }
                return .user(text: text, delivery: state)
            case .botMessage(let sender, let body):
                return .notice(.botMessage(senderName: sender.name, body: body))
            case .systemNotification:
                return .notice(.notification)
            case .processCompletion:
                return .notice(.backgroundTaskFinished)
            }
        case .assistant(let text, _, let streaming):
            if streaming || text.isEmpty { return nil }
            return .assistant(text: text)
        case .tool:
            return nil
        case .clarifyAnswered(let record):
            return .clarifyAnswered(question: record.question, answer: record.answer)
        case .clarify(let card):
            return .clarify(card.prompt)
        case .approval(let card):
            return .approval(card.prompt)
        case .botThread(let link):
            return .botThread(link)
        }
    }

    private func recomputeFind(resetPosition: Bool) {
        let needle = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = currentFindRowID
        guard isFinding || !needle.isEmpty else {
            findMatches = []
            findPosition = 0
            return
        }
        findMatches = needle.isEmpty ? [] : rows.compactMap { row in
            guard let text = row.searchableText,
                  text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { return nil }
            return row.id
        }
        if resetPosition {
            findPosition = max(0, findMatches.count - 1)
        } else if let previous, let index = findMatches.firstIndex(of: previous) {
            findPosition = index
        } else {
            findPosition = min(findPosition, max(0, findMatches.count - 1))
        }
    }

    private static let thinkingRowID = "thinking"

    private var shouldShowThinking: Bool {
        transcript.isRunning && transcript.pendingPrompts.isEmpty
    }
}

struct PreparedUpload: Sendable {
    let data: Data
    let filename: String
    let thumbnail: Data?
}
