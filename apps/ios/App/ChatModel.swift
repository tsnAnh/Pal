import Foundation
import PalChat
import PalDesign
import PalDiagnostics
import PalProtocol
import PalRoster
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
    case backgroundTaskFinished(count: Int, text: String)
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
        case imageGeneration(ImageGeneration)
    }

    let id: String
    let kind: Kind
    let separator: Date?
    let showsUnreadDivider: Bool
    var images: [ImageReference] = []

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

@MainActor
@Observable
final class ChatModel {
    private(set) var rows: [ChatRow] = []
    private(set) var connection: ChatConnectionState = .connecting
    private(set) var isRunning = false
    private(set) var hasPendingClarify = false
    private(set) var sendError: String?
    private var pending = PendingAttachments()
    var attachments: [PendingAttachment] { pending.items }
    private var localImages: [String: Data] = [:]
    private(set) var slashItems: [SlashItem] = []
    private(set) var fileRefResult: FileRefResult?
    private var fileRefTask: Task<Void, Never>?
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
    private(set) var isLoadingOlder = false
    private var findBackfill: Task<Void, Never>?

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

    var hasOlderHistory: Bool { transcript.hasOlder }

    private func hydrateFromCache() {
        guard !hasHydrated else { return }
        hasHydrated = true
        let cache = roster.conversationCache
        let name = openedBot.name
        Task {
            let cached = await Task.detached(priority: .userInitiated) { cache.load(bot: name) }.value
            guard let cached, transcript.sessionID == nil else { return }
            lastCached = cached
            cachedItems = cached.transcriptItems
            rebuild()
            LaunchClock.mark("chat \(name) shown from cache (\(cachedItems.count) items)", on: .osLog())
        }
    }

    @discardableResult
    func loadOlder() async -> Bool {
        guard !isLoadingOlder, transcript.hasOlder, let session else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            guard try await session.loadOlder() else { return false }
            transcript = await session.transcript
            rebuild()
            return true
        } catch {
            return false
        }
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
        let staged = pending.readyToSend
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
        pending.removeAll()
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
        stage(PendingAttachment(kind: .image, name: upload.filename, thumbnail: upload.thumbnail)) { [weak self] session in
            let staged = try await session.attachImage(upload.data, filename: upload.filename)
            await self?.keepLocalImage(upload.data, forHostPath: staged.path)
            return .image(staged.promptAttachment)
        }
    }

    func attachFile(_ upload: PreparedUpload, mime: String) {
        stage(PendingAttachment(kind: .file, name: upload.filename, thumbnail: nil)) { session in
            let staged = try await session.attachFile(upload.data, name: upload.filename, mime: mime)
            return .file(referenceText: staged.refText)
        }
    }

    func removeAttachment(_ id: UUID) {
        pending.remove(id)
    }

    func localImage(for reference: ImageReference) -> Data? {
        guard case .hostPath(let path) = reference.source else { return nil }
        return localImages[path]
    }

    func loadImage(_ reference: ImageReference, thumbnail: Bool) async throws -> Data {
        if let local = localImage(for: reference) { return local }
        do {
            switch reference.source {
            case .inline(let data):
                return data
            case .remote(let url):
                guard url.scheme?.lowercased() == "https" else { throw ImageLoadFailure(reason: "Only secure image links can be opened.") }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    throw ImageLoadFailure(reason: "The image link did not respond.")
                }
                return data
            case .hostPath:
                guard let ref = reference.assetRef, let session else { throw ChatError.notConnected }
                return try await session.imageAsset(ref: ref, thumbnail: thumbnail)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImageLoadFailure(describing: error)
        }
    }

    func keepLocalImage(_ data: Data, forHostPath path: String) {
        localImages[path] = data
    }

    func reportAttachmentFailure(_ message: String) {
        sendError = message
    }

    func beginFinding() {
        isFinding = true
        guard findBackfill == nil else { return }
        findBackfill = Task { [weak self] in
            while let self, self.isFinding, self.transcript.hasOlder, !Task.isCancelled {
                guard await self.loadOlder() else { break }
            }
            if !Task.isCancelled { self?.findBackfill = nil }
        }
    }

    func endFinding() {
        isFinding = false
        findQuery = ""
        findBackfill?.cancel()
        findBackfill = nil
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

    /// Asks the gateway for the files `word` completes to. Keystrokes within the debounce collapse into
    /// one request, a newer word cancels the older one, and a failed or unreachable lookup settles as an
    /// empty answer so the picker shows its quiet empty state instead of waiting.
    func loadFileRefs(word: String) {
        fileRefTask?.cancel()
        fileRefTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let items = (try? await session?.pathCompletions(word: word)) ?? []
            guard !Task.isCancelled else { return }
            fileRefResult = FileRefResult(word: word, items: items)
        }
    }

    private func stage(
        _ attachment: PendingAttachment,
        upload: @escaping @Sendable (ChatSession) async throws -> PendingAttachment.Staged
    ) {
        pending.append(attachment)
        let id = attachment.id
        guard let session else {
            let reason = String(localized: "Attachments need a connection. Try again in a moment.")
            update(id, to: .failed(reason: reason))
            sendError = reason
            return
        }
        Task {
            do {
                update(id, to: .ready(try await upload(session)))
            } catch {
                update(id, to: .failed(reason: String(localized: "It could not be uploaded.")))
                sendError = String(localized: "That attachment could not be uploaded.")
            }
        }
    }

    private func update(_ id: UUID, to state: PendingAttachment.State) {
        pending.setState(state, for: id)
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
            if case .tool(let call) = item.content { return call.imageGeneration != nil }
            return true
        }
        let generated = Set(items.compactMap { item -> String? in
            guard case .tool(let call) = item.content, case .ready(let image)? = call.imageGeneration else { return nil }
            return image.id
        })
        let entries = ChatTimeline.entries(items: items, date: effectiveDate, lastSeen: lastSeenAtOpen)
        let visible = outboxEntries.filter { !retried.contains($0.submissionID) }
        let byID = Dictionary(visible.map { ("submission:\($0.submissionID)", $0) }, uniquingKeysWith: { first, _ in first })
        var built: [ChatRow] = []
        for entry in entries {
            let outbox = byID[entry.item.id]
            guard let (kind, images) = rowKind(for: entry.item, outbox: outbox, generated: generated) else { continue }
            built.append(ChatRow(id: entry.item.id, kind: kind, separator: entry.separator, showsUnreadDivider: entry.showsNewDivider, images: images))
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

    private func rowKind(for item: TranscriptItem, outbox entry: OutboxEntry?, generated: Set<String>) -> (ChatRow.Kind, [ImageReference])? {
        switch item.content {
        case .user(let text, let delivery):
            switch item.inbound {
            case .person:
                var state: BubbleDelivery = switch delivery {
                case .sent, .queued: .sent
                case .sending: isOffline ? .waitingForConnection : .sending
                }
                if let entry, case .failed = entry.state { state = .failed(submissionID: entry.submissionID) }
                var content = MessageImages.extract(from: text, role: .user)
                if let entry, !entry.attachments.isEmpty {
                    let staged = entry.attachments.filter { $0.mime.hasPrefix("image/") }.map { ImageReference(source: .hostPath($0.path)) }
                    var seen: Set<String> = []
                    content.images = (staged + content.images).filter { seen.insert($0.id).inserted }
                    if entry.text.isEmpty, entry.files.isEmpty { content.text = "" }
                }
                return (.user(text: content.text, delivery: state), content.images)
            case .botMessage(let sender, let body):
                return (.notice(.botMessage(senderName: sender.name, body: body)), [])
            case .systemNotification:
                return (.notice(.notification), [])
            case .processCompletion:
                return (.notice(.backgroundTaskFinished(count: InboundKind.backgroundTaskCount(in: text), text: text)), [])
            }
        case .assistant(let text, _, let streaming):
            if streaming { return nil }
            let content = MessageImages.extract(from: text, role: .assistant)
            let images = content.images.filter { !generated.contains($0.id) }
            if content.text.isEmpty, images.isEmpty { return nil }
            return (.assistant(text: content.text), images)
        case .tool(let call):
            guard let generation = call.imageGeneration else { return nil }
            return (.imageGeneration(generation), [])
        case .clarifyAnswered(let record):
            return (.clarifyAnswered(question: record.question, answer: record.answer), [])
        case .clarify(let card):
            return (.clarify(card.prompt), [])
        case .approval(let card):
            return (.approval(card.prompt), [])
        case .botThread(let link):
            return (.botThread(link), [])
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
