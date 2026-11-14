import Foundation
import PalBotProfile
import PalProtocol
import Observation

@MainActor
@Observable
final class LibraryModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed
    }

    private(set) var phase: Phase = .loading
    private(set) var entries: [LibraryEntry] = []
    private(set) var isIndexing = false
    private(set) var isLoadingMore = false
    private(set) var previewFailed = false
    private(set) var preparingEntryID: String?
    var filter: LibraryFilter = .all {
        didSet { if filter != oldValue { reload() } }
    }
    var safariURL: URL?
    var previewURL: URL?

    let botName: String
    private let services: BotsServices
    private var nextBefore: String?
    private var loadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private var previewDirectory: URL?

    static let pollInterval: Duration = .seconds(1.5)
    static let pollLimit = 10

    init(botName: String, services: BotsServices) {
        self.botName = botName
        self.services = services
    }

    var sections: [LibrarySection] { LibraryGrouping.sections(entries) }

    var hasMore: Bool { nextBefore != nil }

    var isEmpty: Bool { phase == .ready && entries.isEmpty }

    func start() {
        guard loadTask == nil, phase == .loading else { return }
        reload()
    }

    func stop() {
        loadTask?.cancel()
        pollTask?.cancel()
        loadTask = nil
        pollTask = nil
    }

    func reload() {
        generation += 1
        let current = generation
        loadTask?.cancel()
        pollTask?.cancel()
        phase = .loading
        entries = []
        nextBefore = nil
        isIndexing = false
        loadTask = Task { await loadFirstPage(generation: current) }
    }

    func retry() {
        reload()
    }

    private func loadFirstPage(generation current: Int) async {
        let key = SurfaceKey.screen("library-\(filter.rawValue)", bot: botName)
        if let cached = await services.surfaces.value(LibraryPage.self, key), current == generation, phase == .loading {
            apply(cached, replacing: true)
            phase = .ready
        }
        do {
            let page = try await services.library.page(profile: botName, filter: filter)
            guard current == generation else { return }
            apply(page, replacing: true)
            phase = .ready
            services.surfaces.persist(page, key)
            if !page.indexComplete { startPolling(generation: current) }
        } catch is CancellationError {
        } catch {
            guard current == generation, phase != .ready else { return }
            phase = .failed
        }
    }

    private func apply(_ page: LibraryPage, replacing: Bool) {
        if replacing {
            entries = page.entries
        } else {
            let known = Set(entries.map(\.id))
            entries += page.entries.filter { !known.contains($0.id) }
        }
        nextBefore = page.nextBefore
        isIndexing = !page.indexComplete
    }

    private func startPolling(generation current: Int) {
        pollTask = Task { [weak self] in
            for _ in 0..<Self.pollLimit {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, current == generation else { return }
                guard let page = try? await services.library.page(profile: botName, filter: filter) else { continue }
                guard current == generation else { return }
                apply(page, replacing: true)
                if page.indexComplete { return }
            }
            guard let self, current == generation else { return }
            isIndexing = false
        }
    }

    func loadMoreIfNeeded(after entry: LibraryEntry) {
        guard entry.id == entries.last?.id, let before = nextBefore, !isLoadingMore, phase == .ready else { return }
        isLoadingMore = true
        let current = generation
        Task {
            defer { if current == generation { isLoadingMore = false } }
            guard let page = try? await services.library.page(profile: botName, filter: filter, before: before), current == generation else { return }
            apply(page, replacing: false)
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
        return try? await services.library.asset(profile: botName, ref: ref, thumbnail: true)
    }

    private func preview(_ entry: LibraryEntry) async {
        guard let ref = entry.assetRef, preparingEntryID == nil else { return }
        preparingEntryID = entry.id
        previewFailed = false
        defer { preparingEntryID = nil }
        do {
            let data = try await services.library.asset(profile: botName, ref: ref, thumbnail: false)
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
