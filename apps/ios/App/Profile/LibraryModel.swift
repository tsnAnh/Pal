import Foundation
import PalBotProfile
import PalDiagnostics
import PalProtocol
import PalRoster
import Observation

@MainActor
@Observable
final class LibraryModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    enum LoadTrigger: Equatable {
        case scroll
        case retry
    }

    enum Pagination: Equatable {
        case more(cursor: String)
        case loading(cursor: String, trigger: LoadTrigger)
        case failed(cursor: String)
        case end

        init(_ page: LibraryPage) {
            self = page.nextBefore.map { .more(cursor: $0) } ?? .end
        }

        func following(_ page: LibraryPage) -> Pagination {
            guard case .failed = self, let cursor = page.nextBefore else { return Pagination(page) }
            return .failed(cursor: cursor)
        }
    }

    private(set) var phase: Phase = .loading
    private(set) var entries: [LibraryEntry] = [] {
        didSet { macItemsVersion &+= 1 }
    }
    private(set) var pagination: Pagination = .end
    private(set) var isIndexing = false
    private(set) var previewFailed = false
    private(set) var preparingEntryID: String?
    var filter: LibraryFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }
    var safariURL: URL?
    var previewURL: URL?

    let botName: String
    private let library: LibraryService
    private let surfaces: SurfaceCache
    private let pollInterval: Duration
    private var loadTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private var previewDirectory: URL?
    @ObservationIgnored private var macItemsVersion = 0
    @ObservationIgnored private var macItemsCache: MacItemsCache?
    @ObservationIgnored private var subtitleCache: [String: String] = [:]

    static let defaultPollInterval: Duration = .seconds(1.5)
    static let pollLimit = 10

    init(botName: String, library: LibraryService, surfaces: SurfaceCache, pollInterval: Duration = LibraryModel.defaultPollInterval) {
        self.botName = botName
        self.library = library
        self.surfaces = surfaces
        self.pollInterval = pollInterval
    }

    convenience init(botName: String, services: BotsServices) {
        self.init(botName: botName, library: services.library, surfaces: services.surfaces)
    }

    var sections: [LibrarySection] { LibraryGrouping.sections(entries) }

    var macItems: [MacLibraryItem] {
        let current = entries
        let day = Calendar.current.startOfDay(for: Date())
        if let cache = macItemsCache, cache.version == macItemsVersion, cache.day == day { return cache.items }
        PalPerf.event("library.mac-items.build", count: current.count)
        let items = MacLibraryItems.make(current, subtitle: { cachedSubtitle(for: $0) })
        macItemsCache = MacItemsCache(version: macItemsVersion, day: day, items: items)
        return items
    }

    private func cachedSubtitle(for entry: LibraryEntry) -> String {
        if let cached = subtitleCache[entry.id] { return cached }
        let text = entry.subtitle()
        subtitleCache[entry.id] = text
        return text
    }

    var hasMore: Bool { pagination != .end }

    var isLoadingMore: Bool {
        if case .loading = pagination { true } else { false }
    }

    var isEmpty: Bool { phase == .ready && entries.isEmpty }

    func start() {
        guard loadTask == nil, phase == .loading else { return }
        reload()
    }

    func stop() {
        loadTask?.cancel()
        loadMoreTask?.cancel()
        pollTask?.cancel()
        loadTask = nil
        loadMoreTask = nil
        pollTask = nil
        if case .loading(let cursor, _) = pagination { pagination = .more(cursor: cursor) }
    }

    func reload() {
        generation += 1
        let current = generation
        loadTask?.cancel()
        loadMoreTask?.cancel()
        pollTask?.cancel()
        loadMoreTask = nil
        subtitleCache = [:]
        assignIfChanged(\.phase, .loading)
        assignIfChanged(\.entries, [])
        assignIfChanged(\.pagination, .end)
        assignIfChanged(\.isIndexing, false)
        loadTask = Task { await loadFirstPage(generation: current) }
    }

    func retry() {
        reload()
    }

    private func loadFirstPage(generation current: Int) async {
        let key = SurfaceKey.screen("library-\(filter.rawValue)", bot: botName)
        if let cached = await surfaces.value(LibraryPage.self, key), current == generation, phase == .loading {
            apply(cached, replacing: true)
            assignIfChanged(\.phase, .ready)
        }
        do {
            let page = try await library.page(profile: botName, filter: filter)
            guard current == generation else { return }
            loadMoreTask?.cancel()
            loadMoreTask = nil
            apply(page, replacing: true)
            assignIfChanged(\.phase, .ready)
            surfaces.persist(page, key)
            if !page.indexComplete { startPolling(generation: current) }
        } catch is CancellationError {
        } catch {
            guard current == generation, phase != .ready else { return }
            phase = .failed
        }
    }

    private func apply(_ page: LibraryPage, replacing: Bool) {
        if replacing {
            assignIfChanged(\.entries, page.entries)
        } else {
            let known = Set(entries.map(\.id))
            let fresh = page.entries.filter { !known.contains($0.id) }
            if !fresh.isEmpty { entries += fresh }
        }
        assignIfChanged(\.pagination, Pagination(page))
        assignIfChanged(\.isIndexing, !page.indexComplete)
    }

    private func refreshHead(with page: LibraryPage) {
        guard let boundary = page.entries.last?.occurredAt else {
            apply(page, replacing: true)
            return
        }
        let headIDs = Set(page.entries.map(\.id))
        let tail = entries.filter { $0.occurredAt < boundary && !headIDs.contains($0.id) }
        assignIfChanged(\.entries, page.entries + tail)
        if tail.isEmpty, !isLoadingMore { assignIfChanged(\.pagination, pagination.following(page)) }
        assignIfChanged(\.isIndexing, !page.indexComplete)
    }

    private func startPolling(generation current: Int) {
        let interval = pollInterval
        pollTask = Task { [weak self] in
            for _ in 0..<Self.pollLimit {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, current == generation else { return }
                guard let page = try? await library.page(profile: botName, filter: filter) else { continue }
                guard current == generation else { return }
                refreshHead(with: page)
                if page.indexComplete { return }
            }
            guard let self, current == generation else { return }
            assignIfChanged(\.isIndexing, false)
        }
    }

    func loadMore() {
        guard phase == .ready, case .more(let cursor) = pagination else { return }
        beginLoadMore(after: cursor, trigger: .scroll)
    }

    func retryLoadMore() {
        guard phase == .ready, case .failed(let cursor) = pagination else { return }
        beginLoadMore(after: cursor, trigger: .retry)
    }

    private func beginLoadMore(after cursor: String, trigger: LoadTrigger) {
        let loading = Pagination.loading(cursor: cursor, trigger: trigger)
        pagination = loading
        let current = generation
        loadMoreTask = Task { await fetchMore(after: cursor, while: loading, generation: current) }
    }

    private func fetchMore(after cursor: String, while loading: Pagination, generation current: Int) async {
        do {
            let page = try await library.page(profile: botName, filter: filter, before: cursor)
            guard current == generation, !Task.isCancelled else { return }
            apply(page, replacing: false)
        } catch {
            guard current == generation, !Task.isCancelled, pagination == loading else { return }
            pagination = .failed(cursor: cursor)
        }
    }

    func open(_ entry: LibraryEntry) {
        switch entry.kind {
        case .link:
            safariURL = entry.url
        case .media, .file:
            guard entry.assetRef != nil else {
                if let url = entry.url { safariURL = url }
                return
            }
            Task { await preview(entry) }
        }
    }

    func thumbnail(for entry: LibraryEntry) async -> Data? {
        guard let ref = entry.assetRef else { return nil }
        return try? await library.asset(profile: botName, ref: ref, thumbnail: true)
    }

    private func preview(_ entry: LibraryEntry) async {
        guard let ref = entry.assetRef, preparingEntryID == nil else { return }
        preparingEntryID = entry.id
        previewFailed = false
        defer { preparingEntryID = nil }
        do {
            let data = try await library.asset(profile: botName, ref: ref, thumbnail: false)
            let directory = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = (entry.title as NSString).lastPathComponent
            let url = directory.appending(path: name.isEmpty ? "item" : name, directoryHint: .notDirectory)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            previewDirectory = directory
            previewURL = url
        } catch is CancellationError {
        } catch {
            previewFailed = true
        }
    }

    func cleanUpPreview() {
        guard previewURL == nil, let directory = previewDirectory else { return }
        previewDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func dismissPreviewFailure() {
        previewFailed = false
    }
}
