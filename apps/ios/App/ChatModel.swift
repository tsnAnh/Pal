import Foundation
import PalChat
import PalDesign
import PalDiagnostics
import PalProtocol
import PalRoster
import Observation

@MainActor
@Observable
final class ChatModel {
    private(set) var rows: [ChatRow] = []
    private(set) var rowsNewestFirst: [ChatRow] = []
    private(set) var rowIDs: [String] = []
    private(set) var windowRange: Range<Int> = 0..<0
    @ObservationIgnored var window = ChatRowWindow()
    @ObservationIgnored let diagnostics = Diagnostics.osLog()
    private(set) var connection: ChatConnectionState = .connecting
    private(set) var isRunning = false
    private(set) var workingStatus: String?
    private(set) var hasPendingClarify = false
    private(set) var hasPendingPrompt = false
    private(set) var newestRowIsQuestion = false
    @ObservationIgnored var settledPrompts: [String: ClarifySettled] = [:]
    private(set) var olderHistory = OlderHistory.idle
    var isOpening = true
    var sendError: String?
    private(set) var answeringConnections: Set<String> = []
    var pending = PendingAttachments()
    var restoredDraft: String?
    @ObservationIgnored var draftWork: Task<Void, Never>?
    var attachments: [PendingAttachment] { pending.items }
    private var localImages: [String: Data] = [:]
    private(set) var slashItems: [SlashItem] = []
    private(set) var fileRefResult: FileRefResult?
    private var fileRefTask: Task<Void, Never>?
    private(set) var reactions: [String: String] = [:]
    private(set) var replyTarget: ReplyTarget?
    var isFinding = false
    var imageViewer: ImageViewerState?
    var documentViewer: DocumentViewerState?
    var filePreview: FileReference?
    var findQuery = "" {
        didSet { findQueryChanged() }
    }
    private(set) var findMatches: [String] = [] {
        didSet { findMatchIDs = Set(findMatches) }
    }
    private(set) var findMatchIDs: Set<String> = []
    private(set) var findPosition = 0

    let openedBot: BotRow
    var bot: BotRow { roster.bot(named: openedBot.name) ?? openedBot }

    let links: BotLinks
    let roster: RosterModel
    private let lastSeenStore: ChatLastSeenStore
    private(set) var lastSeenAtOpen: Date?
    private var link: BotLink?
    var session: ChatSession?
    private var outbox: Outbox?
    var snapshot: TimelineSnapshot?
    private var outboxEntries: [OutboxEntry] = []
    var arrivals: [String: Date] = [:]
    @ObservationIgnored private var identity = ChatRowIdentity()
    private var outboxRowIDs: Set<String> = []
    private var unsaved: [OutboxEntry] = []
    @ObservationIgnored private var echoLedger = AdmittedEchoLedger()
    @ObservationIgnored private var reapable: Set<String> = []
    @ObservationIgnored private var reaping: Set<String> = []
    var built: [String: BuiltRow] = [:]
    var hasBaseline = false
    @ObservationIgnored var builtOffline = true
    @ObservationIgnored var builtWithBaseline = false
    @ObservationIgnored var generatedImageIDs: Set<String> = []
    @ObservationIgnored private(set) var rebuilds = RebuildCounts()
    let streamPacer = StreamingCommitPacer()
    private var hasBeenLive = false
    private var lastSignature = ActivitySignature(running: false, prompting: false)
    private var running: Task<Void, Never>?
    @ObservationIgnored var openingDeadline: Task<Void, Never>?
    @ObservationIgnored var openStats = ChatOpenStats()
    private var delivering = false
    private var absorbedEchoes = AbsorbedEchoLedger()

    let opening = ChatOpenCoordinator()
    let layout = ChatLayoutMemory()
    private(set) var isActive = false
    private var openCount = 0
    private var findSearch: Task<Void, Never>?
    private var pendingReveal: RowKey?

    private struct ActivitySignature: Equatable {
        let running: Bool
        let prompting: Bool
    }

    struct BuiltRow {
        let item: TranscriptItem
        let kind: ChatRow.Kind?
        let images: [ImageReference]
        var files: [FileReference] = []
    }

    var isOpenWindow: Bool { opening.isWindowOpen }
    var pendingDraft: String? { roster.drafts[bot.name] }
    var avatarMood: AvatarMood { roster.avatarMood(for: bot.name) }
    var canSendAttachments: Bool {
        !attachments.contains { $0.state == .uploading }
    }

    var currentFindRowID: String? {
        findMatches.indices.contains(findPosition) ? findMatches[findPosition] : nil
    }

    init(bot: BotRow, links: BotLinks, roster: RosterModel, lastSeenStore: ChatLastSeenStore = ChatLastSeenStore()) {
        openedBot = bot
        self.links = links
        self.roster = roster
        self.lastSeenStore = lastSeenStore
        lastSeenAtOpen = lastSeenStore.lastSeen(for: bot.name)
        seedFromMemory()
    }

    func wantOlder() {
        if hiddenOlder > 0 { return expandWindow() }
        guard let session, olderHistory.canLoad else { return }
        Task { await session.wantOlder() }
    }

    func start() {
        roster.markRead(bot.name)
        guard running == nil else { return }
        ChatOpenTrace.begin(bot: bot.name)
        armOpeningDeadline()
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
        flushDraft()
        markViewed()
        ChatOpenTrace.finish(bot: bot.name)
        running?.cancel()
        running = nil
        closeOpening()
        opening.cancel()
        findSearch?.cancel()
        findSearch = nil
        let session = self.session
        let link = self.link
        self.session = nil
        self.link = nil
        outbox = nil
        if let session, let link { Task { await link.sessions.release(session) } }
        roster.nudge()
    }

    func setForeground(_ active: Bool) {
        if let session { Task { await session.setForeground(active) } }
    }

    func markViewed() {
        if let session { Task { await session.flushCache() } }
        guard hasBaseline else { return }
        lastSeenStore.record(Date(), for: bot.name)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = pending.readyToSend
        guard !trimmed.isEmpty || !staged.isEmpty, canSendAttachments else { return }
        if let prompt = pendingClarify, staged.isEmpty {
            answerFromComposer(prompt, text: trimmed)
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
        let sentAttachments = pending.removeAll()
        let provisional = OutboxEntry(
            submissionID: UUID().uuidString, botID: bot.name, text: body, attachments: images,
            createdAt: Date(), state: .pending, attempts: 0
        )
        unsaved.append(provisional)
        outboxEntries.append(provisional)
        rebuild()
        Task {
            do {
                let entry = try await outbox.enqueue(
                    botID: bot.name, text: body, attachments: images, submissionID: provisional.submissionID
                )
                unsaved.removeAll { $0.submissionID == entry.submissionID }
                forgetInDraft(sentAttachments.map(\.id))
                await refreshOutbox()
                _ = await outbox.deliver(entry.submissionID)
                await refreshOutbox()
            } catch {
                unsaved.removeAll { $0.submissionID == provisional.submissionID }
                await refreshOutbox()
                keepDraft(text: text, attachments: sentAttachments)
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
            await refreshOutbox()
            _ = await outbox.deliver(entry.submissionID)
            await refreshOutbox()
        }
    }

    func answerConnection(opID: String, target: String, decision: ConnectionDecision) {
        guard let session else { return }
        let key = ConnectionRequestCard.answerKey(opID: opID, target: target)
        guard answeringConnections.insert(key).inserted else { return }
        Task {
            defer { answeringConnections.remove(key) }
            do {
                try await session.answerConnection(opID: opID, target: target, decision: decision)
            } catch {
                sendError = String(localized: "Your answer could not be sent. Try again.")
            }
        }
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

    func attachPhoto(_ upload: PreparedUpload, id: UUID = UUID(), remember: Bool = true) {
        let attachment = PendingAttachment(id: id, kind: .image, name: upload.filename, thumbnail: upload.thumbnail)
        if remember { rememberInDraft(attachment, data: upload.data, mime: Self.imageMime(of: upload.filename)) }
        stage(attachment) { [weak self] session in
            let staged = try await session.attachImage(upload.data, filename: upload.filename)
            await self?.keepLocalImage(upload.data, forHostPath: staged.path)
            return .image(staged.promptAttachment)
        }
    }

    func attachFile(_ upload: PreparedUpload, mime: String, id: UUID = UUID(), remember: Bool = true) {
        let attachment = PendingAttachment(id: id, kind: .file, name: upload.filename, thumbnail: nil)
        if remember { rememberInDraft(attachment, data: upload.data, mime: mime) }
        stage(attachment) { session in
            let staged = try await session.attachFile(upload.data, name: upload.filename, mime: mime)
            return .file(referenceText: staged.refText)
        }
    }

    func removeAttachment(_ id: UUID) {
        pending.remove(id)
        forgetInDraft([id])
    }

    var imageLoader: ChatImageLoader {
        { [self] reference, thumbnail in try await loadImage(reference, thumbnail: thumbnail) }
    }

    var fileActions: ChatFileActions {
        ChatFileActions(
            check: { [self] in try await fileAvailability($0) }, load: { [self] in try await loadFile($0) }
        )
    }

    func openImage(_ reference: ImageReference, inRow rowID: String) {
        let images = ConversationImages.list(from: rows.map { row -> ConversationImages.Row in
            if case .imageGeneration(.ready(let image)) = row.kind { return .init(rowID: row.id, text: row.searchableText, images: [image]) }
            return .init(rowID: row.id, text: row.searchableText, images: row.images)
        })
        imageViewer = ImageViewerState(images: images, opening: "\(rowID)/\(reference.id)", anchorRowID: rowID)
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

    func fileAvailability(_ reference: FileReference) async throws -> FileAvailability {
        guard let session else { throw ChatError.notConnected }
        return try await session.fileAvailability(ref: reference.id)
    }

    func loadFile(_ reference: FileReference) async throws -> Data {
        guard let session else { throw ChatError.notConnected }
        return try await session.fileAsset(ref: reference.id)
    }

    func keepLocalImage(_ data: Data, forHostPath path: String) {
        localImages[path] = data
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
        findSearch?.cancel()
        findSearch = nil
        pendingReveal = nil
    }

    func findNext() {
        guard !findMatches.isEmpty else { return }
        assignIfChanged(\.findPosition, (findPosition + 1) % findMatches.count)
    }

    func findPrevious() {
        guard !findMatches.isEmpty else { return }
        guard findPosition == 0, olderHistory.canLoad else {
            assignIfChanged(\.findPosition, (findPosition - 1 + findMatches.count) % findMatches.count)
            return
        }
        searchOlder(excluding: Set(findMatches))
    }

    func loadSlashItems() {
        guard slashItems.isEmpty, let session else { return }
        Task {
            if let items = try? await session.slashCommands() { slashItems = items }
        }
    }

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
        if let stored = row.storedRowID { return .row(stored) }
        let newest = rows.last { candidate in
            switch candidate.kind {
            case .user: role == "user"
            case .assistant: role == "assistant"
            default: false
            }
        }
        return newest?.id == rowID ? .newest(role: role) : nil
    }

    private var pendingClarify: PendingPrompt? {
        snapshot?.pendingPrompts.first { $0.kind == .clarify && !$0.isForm }
    }

    private func run(_ link: BotLink) async {
        let session = await link.sessions.acquire()
        guard !Task.isCancelled else {
            await link.sessions.release(session)
            return
        }
        self.session = session
        var warm = false
        if case .live = await session.phase {
            warm = true
            noteLive()
        }
        let before = await session.timelineSnapshot
        await restoreSession(session)
        await restoreDraft()
        let current = await session.timelineSnapshot
        if before.rows.isEmpty, !current.rows.isEmpty {
            showCacheFrame(current)
        } else {
            apply(current)
        }
        if warm { await session.refresh() }
        async let timeline: Void = consumeTimeline(session)
        async let phases: Void = consumePhases(session)
        async let retrying: Void = retryLoop()
        await attach(session)
        await timeline
        await phases
        await retrying
    }

    private func attach(_ session: ChatSession) async {
        let preparing = PalPerf.begin("chat.open.outbox")
        await refreshOutbox()
        preparing.end()
        var delay = Duration.milliseconds(500)
        let intro = roster.takeIntro(for: bot.name)
        while !Task.isCancelled {
            do {
                try await session.start(intro: intro)
                guard let settled = await session.settledPhase() else { return }
                if settled != .detached { return }
            } catch {}
            opening.retrying(after: delay)
            noteDisconnected()
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }
    }

    private func noteDisconnected() {
        assignIfChanged(\.connection, hasBeenLive ? .reconnecting : .connecting)
    }

    private func noteLive() {
        if !hasBeenLive {
            LaunchClock.mark("chat \(openedBot.name) live", on: .osLog())
            ChatOpenTrace.mark(openedBot.name, "live")
        }
        hasBeenLive = true
        assignIfChanged(\.connection, .live)
    }

    private func consumePhases(_ session: ChatSession) async {
        for await update in session.updates {
            guard case .phase(let phase) = update else { continue }
            applyPhase(phase)
        }
    }

    func applyPhase(_ phase: ChatPhase) {
        if case .live = phase { noteLive() } else { noteDisconnected() }
        if builtOffline != isOffline { rebuild() }
    }

    private func consumeTimeline(_ session: ChatSession) async {
        await TimelinePacer.consume(session.timelineSnapshots, apply: { next in
            guard let ready = opening.admit(next) else { return }
            apply(ready)
        })
        diagnostics.notice("chat", "model \(openedBot.name) timeline.ended cancelled=\(Task.isCancelled)")
    }

    func apply(_ next: TimelineSnapshot) {
        guard acceptsSnapshot(next) else {
            diagnostics.notice("chat", "model \(openedBot.name) snapshot.dropped version=\(next.version) rows=\(next.rows.count)")
            return
        }
        let previous = takePreviousSnapshot()
        snapshot = next
        assignIfChanged(\.olderHistory, OlderHistory(next.older))
        rebuild(patching: previous)
        observeActivityChange()
        resolvePendingReveal()
        ChatOpenTrace.frameApplied(bot: openedBot.name, version: next.version, rows: next.rows.count)
        traceOpen("apply")
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
        let stored = await outbox?.snapshot(botID: bot.name) ?? []
        let storedIDs = Set(stored.map(\.submissionID))
        outboxEntries = stored + unsaved.filter { !storedIDs.contains($0.submissionID) }
        rebuild()
    }

    private func reapAdmitted() {
        let doomed = reapable.subtracting(reaping)
        guard let outbox, !doomed.isEmpty else { return }
        reaping.formUnion(doomed)
        Task {
            do { try await outbox.discardAdmitted(doomed) } catch { return }
            reaping.subtract(doomed)
            await refreshOutbox()
        }
    }

    private func observeActivityChange() {
        let signature = ActivitySignature(running: snapshot?.isRunning ?? false, prompting: isAskingClarify)
        defer { lastSignature = signature }
        if signature != lastSignature { roster.nudge() }
    }

    private func displayText(for entry: OutboxEntry) -> String {
        if !entry.text.isEmpty { return entry.text }
        if !entry.files.isEmpty { return entry.files.map(\.name).joined(separator: ", ") }
        return entry.attachments.isEmpty ? "" : String(localized: "Photo")
    }

    func rowID(for row: ChatTimelineRow) -> String {
        identity.ids(
            for: [row], outboxIDs: outboxRowIDs, forwarded: snapshot?.forwardedKeys ?? [:]
        )[0]
    }

    private func sourceItems() -> [(id: String, item: TranscriptItem, stored: Int?)] {
        let timelineRows = snapshot?.rows ?? []
        let echoed = echoLedger.resolve(
            entries: outboxEntries, text: displayText(for:), timeline: timelineRows.map(\.item)
        )
        let echoedBy = Dictionary(echoed.echoes.map { ($0.value, $0.key) }, uniquingKeysWith: { min($0, $1) })
        for row in timelineRows {
            if let submissionID = echoedBy[row.item.id] { identity.keep("submission:\(submissionID)", for: row.id) }
        }
        let staleBefore = Date().addingTimeInterval(-AdmittedEchoLedger.retention)
        reapable = Set(echoed.echoes.keys)
        if hasBaseline {
            reapable.formUnion(outboxEntries.filter { $0.state.isAdmitted && $0.createdAt < staleBefore }.map(\.submissionID))
        }
        let unechoed = Set(echoed.unechoed.map(\.submissionID))
        let timelineIDs = identity.ids(
            for: timelineRows, outboxIDs: outboxRowIDs, forwarded: snapshot?.forwardedKeys ?? [:]
        )
        var sources = zip(timelineRows, timelineIDs).map { (id: $1, item: $0.item, stored: $0.rowID) }
        let known = Set(timelineRows.map(\.item.id)).union(sources.map(\.id))
        let awaiting = outboxEntries.filter { entry in
            entry.state == .pending && !known.contains("submission:\(entry.submissionID)")
        }
        let absorbed = absorbedEchoes.hiddenSubmissions(
            pending: awaiting.map { AbsorbedEchoLedger.Pending(submissionID: $0.submissionID, text: displayText(for: $0)) },
            absorbed: timelineRows.map(\.item).filter { $0.id.hasPrefix("absorbed:") }
        )
        var shownOutbox: Set<String> = []
        for entry in outboxEntries {
            let id = "submission:\(entry.submissionID)"
            guard !known.contains(id), !absorbed.contains(entry.submissionID) else { continue }
            if entry.state.isAdmitted, !unechoed.contains(entry.submissionID) { continue }
            let delivery: TranscriptItem.Delivery = entry.state.isAdmitted ? .sent : .sending
            var item = TranscriptItem(id: id, content: .user(text: displayText(for: entry), delivery: delivery), timestamp: entry.createdAt)
            if case .failed(let reason) = entry.state { item.deliveryFailure = reason }
            sources.append((id: id, item: item, stored: nil))
            shownOutbox.insert(id)
        }
        outboxRowIDs.formUnion(shownOutbox)
        return sources
    }

    func rebuild(patching previous: TimelineSnapshot? = nil) {
        let perf = PalPerf.begin("chat.rebuild"); defer { perf.end() }
        if let previous, let snapshot, let patch = streamingPatch(from: previous, to: snapshot) {
            rebuilds.patched += 1
            commit(patch)
        } else {
            rebuilds.full += 1
            streamPacer.reset()
            publish(builtRows())
            reapAdmitted()
        }
        builtOffline = isOffline
        publishActivity()
    }

    private func builtRows() -> [ChatRow] {
        let now = Date()
        builtWithBaseline = hasBaseline
        let sources = sourceItems()
        for source in sources where hasBaseline && source.item.timestamp == nil && arrivals[source.item.id] == nil {
            arrivals[source.item.id] = now
        }
        let generated = Set(sources.compactMap { source -> String? in
            guard case .tool(let call) = source.item.content, case .ready(let image)? = call.imageGeneration else { return nil }
            return image.id
        })
        generatedImageIDs = generated
        let entries = ChatTimeline.entries(
            items: sources.map(\.item),
            date: { [arrivals] item in item.timestamp ?? arrivals[item.id] },
            lastSeen: lastSeenAtOpen
        )
        let entryByItem = Dictionary(entries.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        let outboxByItem = Dictionary(
            outboxEntries.map { ("submission:\($0.submissionID)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var next: [ChatRow] = []
        var nextBuilt: [String: BuiltRow] = [:]
        next.reserveCapacity(sources.count)
        for source in sources {
            guard let entry = entryByItem[source.item.id] else { continue }
            let outboxEntry = outboxByItem[source.item.id]
            let made = build(source.item, outbox: outboxEntry, generated: generated, reuse: outboxEntry == nil ? built[source.id] : nil)
            nextBuilt[source.id] = made
            guard let kind = made.kind, !Self.isEmpty(kind, images: made.images, files: made.files) else { continue }
            var row = ChatRow(id: source.id, kind: kind, separator: entry.separator, showsUnreadDivider: entry.showsNewDivider)
            row.images = made.images
            row.files = made.files
            if case .assistant(_, _, let streaming) = made.item.content { row.isStreaming = streaming }
            row.storedRowID = source.stored
            next.append(row)
        }
        (built, next) = (nextBuilt, ChatRow.mergingClarifyAnswers(next, sources: sources.map { ($0.id, $0.item.id) }))
        for index in next.indices {
            next[index].gap = Self.gap(for: next[index], after: index > 0 ? next[index - 1] : nil)
        }
        Self.flagDuplicateIDs(in: next)
        return next
    }

    private func publish(_ next: [ChatRow]) {
        noteRows(next.count)
        if assignIfChanged(\.rows, next) {
            assignIfChanged(\.rowsNewestFirst, Array(next.reversed()), force: true)
            assignIfChanged(\.rowIDs, next.map(\.id))
            assignIfChanged(\.newestRowIsQuestion, next.last?.kind.isQuestionCard ?? false)
        }
        publishWindow()
    }

    func show(_ patch: StreamingRowPatch) {
        guard let last = rows.indices.last, rows[last].id == patch.row.id, rows[last] != patch.row else { return }
        (rows[last], rowsNewestFirst[0]) = (patch.row, patch.row)
    }

    private func publishActivity() {
        assignIfChanged(\.isRunning, snapshot?.isRunning ?? false)
        assignIfChanged(\.workingStatus, snapshot?.runningToolName.map(ToolActivity.label(for:)))
        assignIfChanged(\.hasPendingClarify, pendingClarify != nil)
        assignIfChanged(\.hasPendingPrompt, !(snapshot?.pendingPrompts.isEmpty ?? true) || snapshot?.hasPendingConnection == true)
        if !hasBaseline, snapshot?.sessionID != nil { hasBaseline = true }
        if isOpening, !rows.isEmpty || snapshot?.sessionID != nil { endOpening("opened") }
        opening.rowsChanged()
        recomputeFind(resetPosition: false)
    }

    func build(_ item: TranscriptItem, outbox entry: OutboxEntry?, generated: Set<String>, reuse: BuiltRow?) -> BuiltRow {
        if let reuse, reuse.item == item, !Self.dependsOnConnection(item), !hasStaleClarify(item, reuse) {
            if case .assistant = item.content, !generated.isEmpty {
                return BuiltRow(item: item, kind: reuse.kind, images: reuse.images.filter { !generated.contains($0.id) }, files: reuse.files)
            }
            return reuse
        }
        guard let (kind, images, files) = rowKind(for: item, outbox: entry, generated: generated, previous: reuse) else {
            return BuiltRow(item: item, kind: nil, images: [])
        }
        return BuiltRow(item: item, kind: kind, images: images, files: files)
    }

    private func rowKind(for item: TranscriptItem, outbox entry: OutboxEntry?, generated: Set<String>, previous: BuiltRow?) -> (ChatRow.Kind, [ImageReference], [FileReference])? {
        switch item.content {
        case .user(let text, let delivery):
            switch item.inbound {
            case .person:
                var state: BubbleDelivery = switch delivery {
                case .sent, .queued: .sent
                case .sending: .awaitingReceipt(offline: isOffline, outbox: entry)
                }
                if let entry, case .failed = entry.state { state = .failed(submissionID: entry.submissionID) }
                var content = MessageImages.extract(from: text, role: .user)
                if let entry, !entry.attachments.isEmpty {
                    let staged = entry.attachments.filter { $0.mime.hasPrefix("image/") }.map { ImageReference(source: .hostPath($0.path)) }
                    var seen: Set<String> = []
                    content.images = (staged + content.images).filter { seen.insert($0.id).inserted }
                    if entry.text.isEmpty, entry.files.isEmpty { content.text = "" }
                }
                return (.user(text: content.text, delivery: state), content.images, [])
            case .botMessage(let sender, let body):
                return (.notice(.botMessage(senderName: sender.name, body: body)), [], [])
            case .routineOutput(_, let body, let failed):
                return (.routine(RoutineMessage(body: body, failed: failed)), [], [])
            case .internalNotice: return nil
            }
        case .assistant(let text, _, let streaming):
            let content = MessageImages.extract(from: text, role: .assistant, isStreaming: streaming)
            let images = content.images.filter { !generated.contains($0.id) }
            if case .assistant(let parsed)? = previous?.kind, parsed.source == content.text {
                return (.assistant(parsed), images, content.files)
            }
            return (.assistant(.deferringWarm(content.text, isStreaming: streaming)), images, content.files)
        case .tool(let call):
            let generation = call.imageGeneration
            return generation.map { (.imageGeneration($0), [], []) }
        case .clarifyAnswered(let record):
            return (.clarifyAnswered([record]), [], [])
        case .clarify(let card):
            return (settledKind(for: card) ?? .clarify(card.prompt), [], [])
        case .connection(let card):
            return (.connection(card), [], [])
        case .noProvider: return (.noProvider, [], [])
        case .botThread(let link): return (.botThread(link), [], [])
        }
    }

    private func findQueryChanged() {
        recomputeFind(resetPosition: true)
        findSearch?.cancel()
        findSearch = nil
        pendingReveal = nil
        if findMatches.isEmpty { searchOlder(excluding: [], after: .milliseconds(300)) }
    }

    private func searchOlder(excluding known: Set<String>, after pause: Duration = .zero) {
        let needle = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let session, olderHistory.canLoad else { return }
        let knownKeys = Set((snapshot?.rows ?? []).filter { known.contains(rowID(for: $0)) }.map(\.id))
        findSearch?.cancel()
        findSearch = Task { [weak self] in
            if pause > .zero, (try? await Task.sleep(for: pause)) == nil { return }
            let key = await session.reveal { row in
                !knownKeys.contains(row.id) && Self.matches(row.item, needle: needle)
            }
            guard !Task.isCancelled, let self, let key else { return }
            self.pendingReveal = key
            self.resolvePendingReveal()
        }
    }

    private func resolvePendingReveal() {
        guard let key = pendingReveal, let row = snapshot?.rows.first(where: { $0.id == key }) else { return }
        pendingReveal = nil
        let id = rowID(for: row)
        recomputeFind(resetPosition: false)
        if let index = findMatches.firstIndex(of: id) { assignIfChanged(\.findPosition, index) }
    }

    nonisolated private static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    nonisolated private static func matches(_ item: TranscriptItem, needle: String) -> Bool {
        let text: String
        switch item.content {
        case .user(let body, _): text = body
        case .assistant(let body, _, _): text = body
        default: return false
        }
        return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func recomputeFind(resetPosition: Bool) {
        guard isFinding || !findQuery.isEmpty else {
            assignIfChanged(\.findMatches, [])
            assignIfChanged(\.findPosition, 0)
            return
        }
        let needle = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = currentFindRowID
        assignIfChanged(\.findMatches, needle.isEmpty ? [] : rows.flatMap { row in
            Array(repeating: row.id, count: row.searchableText.map { Self.occurrences(of: needle, in: $0) } ?? 0)
        })
        if resetPosition {
            assignIfChanged(\.findPosition, max(0, findMatches.count - 1))
        } else if let previous, let index = findMatches.firstIndex(of: previous) {
            assignIfChanged(\.findPosition, index)
        } else {
            assignIfChanged(\.findPosition, min(findPosition, max(0, findMatches.count - 1)))
        }
    }
}

struct PreparedUpload: Sendable {
    let data: Data
    let filename: String
    let thumbnail: Data?
}

extension ChatModel {
    func publishWindow() {
        assignIfChanged(\.windowRange, window.resolve(rowIDs))
        traceOpen("window")
    }
}
