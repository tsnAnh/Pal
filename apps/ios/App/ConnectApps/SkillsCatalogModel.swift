import Foundation
import PalConnect
import PalDesign
import PalDiagnostics
import PalProtocol
import Observation

@MainActor
@Observable
final class SkillsCatalogModel {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable
    }

    enum DetailPhase: Equatable {
        case loading
        case loaded(SkillDetail)
        case failed(String)
    }

    struct Outcome: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isSuccess: Bool
    }

    struct KeyRequest: Identifiable, Equatable {
        let skill: String
        let keyName: String

        var id: String { "\(skill)/\(keyName)" }
    }

    private static let allKey = "all"

    private(set) var phase: Phase = .loading
    private(set) var busy: Set<String> = []
    private(set) var outcome: Outcome?
    private(set) var detailPhase: DetailPhase = .loading
    private(set) var isLoadingMore = false
    private(set) var searchHits: [SkillHubItem] = []
    var filter: SkillFilter = .all
    var query = ""
    var removeTarget: SkillRow?
    var keyRequest: KeyRequest?
    private(set) var keyState: SecretEntryState = .idle

    private var catalog = SkillsCatalog()
    private var hub: [SkillHubItem] = []
    private var state = SkillsInstallState.empty
    private var page = 0
    private var totalPages = 1
    private var detailSeed: SkillRow?

    private var refreshed = false

    private struct Snapshot: Sendable {
        let hub: [SkillHubItem]
        let state: SkillsInstallState
        let page: Int
        let totalPages: Int
    }

    private let service: SkillsCatalogService
    private let diagnostics = Diagnostics.osLog()
    private let surfaces: SurfaceCache
    private let surfaceKey: SurfaceKey

    init(service: SkillsCatalogService, profile: String?, surfaces: SurfaceCache) {
        self.service = service
        self.surfaces = surfaces
        surfaceKey = .screen("skills-catalog", bot: profile ?? "")
        if let held = surfaces.remembered(Snapshot.self, surfaceKey) {
            hub = held.hub
            state = held.state
            page = held.page
            totalPages = held.totalPages
            rebuild()
            phase = .ready
        }
    }

    private func remember() {
        surfaces.remember(Snapshot(hub: hub, state: state, page: page, totalPages: totalPages), surfaceKey)
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var rows: [SkillRow] { catalog.results(for: trimmedQuery, filter: filter, remote: searchHits) }

    var updatableCount: Int { catalog.updatableCount }

    var canLoadMore: Bool { phase == .ready && page < totalPages && trimmedQuery.isEmpty && filter == .all }

    var isMutating: Bool { !busy.isEmpty }

    func isWorking(on row: SkillRow) -> Bool { busy.contains(row.id) }

    var isUpdatingAll: Bool { busy.contains(Self.allKey) }

    var detail: SkillRow? {
        guard let seed = detailSeed else { return nil }
        if let current = catalog.rows.first(where: { $0.id == seed.id }) { return current }
        let item = SkillHubItem(name: seed.name, summary: seed.summary, source: seed.source, trust: seed.trust, identifier: seed.identifier)
        return SkillsCatalog(hub: [item], state: state, includeUnlisted: false).rows.first ?? seed
    }

    func start() async {
        guard !refreshed else { return }
        await load()
    }

    func load() async {
        if phase != .ready { phase = .loading }
        do {
            async let first = service.browse(page: 1)
            async let installed = service.installState()
            let (firstPage, installState) = try await (first, installed)
            hub = firstPage.items
            page = firstPage.page
            totalPages = firstPage.totalPages
            state = installState
            rebuild()
            phase = .ready
            refreshed = true
            remember()
        } catch is CancellationError {
            return
        } catch {
            if phase == .ready {
                outcome = Outcome(message: Self.message(error), isSuccess: false)
            } else {
                phase = .unavailable
            }
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await service.browse(page: page + 1)
            hub += next.items
            page = next.page
            totalPages = next.totalPages
            rebuild()
        } catch is CancellationError {
            return
        } catch {
            outcome = Outcome(message: Self.message(error), isSuccess: false)
        }
    }

    func runSearch() async {
        let needle = trimmedQuery
        guard !needle.isEmpty else {
            searchHits = []
            return
        }
        do {
            let hits = try await service.search(needle)
            if trimmedQuery == needle { searchHits = hits }
        } catch is CancellationError {
            return
        } catch {
            diagnostics.info("skills", "search failed: \(Diagnostics.describe(error))")
            if trimmedQuery == needle { searchHits = [] }
        }
    }

    func openDetail(_ row: SkillRow) {
        outcome = nil
        detailSeed = row
        detailPhase = .loading
    }

    func closeDetail() {
        outcome = nil
        detailSeed = nil
    }

    func loadDetail() async {
        guard let seed = detailSeed else { return }
        detailPhase = .loading
        do {
            let loaded = try await service.inspect(seed.installTarget)
            if detailSeed?.id == seed.id { detailPhase = .loaded(loaded) }
        } catch is CancellationError {
            return
        } catch {
            if detailSeed?.id == seed.id { detailPhase = .failed(Self.message(error)) }
        }
    }

    func beginKeyEntry(_ row: SkillRow, keyName: String) {
        guard row.isInstalled else { return }
        keyState = .idle
        keyRequest = KeyRequest(skill: row.managedName ?? row.name, keyName: keyName)
    }

    func cancelKeyEntry() {
        keyRequest = nil
        keyState = .idle
    }

    func submitKey(_ value: String) async {
        guard let request = keyRequest, keyState.acceptsInput else { return }
        keyState = .submitting
        do {
            try await service.setKey(skill: request.skill, keyName: request.keyName, value: SecretString(value))
            cancelKeyEntry()
            outcome = Outcome(message: String(localized: "\(request.keyName) saved."), isSuccess: true)
        } catch is CancellationError {
            keyState = .idle
        } catch {
            let message = Self.message(error)
            keyState = .failure(message)
            outcome = Outcome(message: message, isSuccess: false)
        }
    }

    func dismissOutcome() {
        outcome = nil
    }

    func install(_ row: SkillRow) async {
        await perform(key: row.id, success: String(localized: "\(row.name) installed.")) { try await service.install(row.installTarget) }
    }

    func update(_ row: SkillRow) async {
        guard let name = row.managedName else { return }
        await perform(key: row.id, success: String(localized: "\(row.name) updated.")) { try await service.update(name: name) }
    }

    func updateAll() async {
        await perform(key: Self.allKey, success: String(localized: "All skills are up to date.")) { try await service.update(name: nil) }
    }

    func confirmRemove() async {
        guard let row = removeTarget else { return }
        removeTarget = nil
        guard let name = row.managedName else { return }
        await perform(key: row.id, success: String(localized: "\(row.name) removed.")) { try await service.uninstall(name: name) }
    }

    private func perform(key: String, success: String, _ work: () async throws -> Void) async {
        guard busy.isEmpty else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        outcome = nil
        do {
            try await work()
        } catch is CancellationError {
            return
        } catch {
            outcome = Outcome(message: Self.message(error), isSuccess: false)
            return
        }
        do {
            state = try await service.installState()
            rebuild()
            remember()
            outcome = Outcome(message: success, isSuccess: true)
        } catch {
            outcome = Outcome(
                message: String(localized: "Done, but the list couldn't refresh. Close and reopen Skills to see the latest."), isSuccess: false
            )
        }
    }

    private func rebuild() {
        catalog = SkillsCatalog(hub: hub, state: state)
    }

    private static func message(_ error: any Error) -> String {
        (error as? SkillsCatalogError ?? .unavailable).userMessage
    }
}
