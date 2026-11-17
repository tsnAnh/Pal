import Foundation
import PalConnect
import Observation

@MainActor
@Observable
final class LegacyConnectionsModel {
    enum Display: Equatable {
        case hidden
        case rows([LegacyReconnectRow])
        case unreadable(code: String)
    }

    static let unreadableCode = "legacy_source_unreadable"
    static let failedCode = "legacy_request_failed"

    private enum Phase: Equatable {
        case idle
        case loaded(LegacyConnectionsResult)
        case failed
    }

    private var phase: Phase = .idle
    private(set) var isLoading = false
    private var dismissed: Set<String>

    private let service: ConnectAppsService
    private let profile: String?
    private let store: any LegacyDismissals

    init(service: ConnectAppsService, profile: String?, store: any LegacyDismissals = UserDefaultsLegacyDismissals()) {
        self.service = service
        self.profile = profile
        self.store = store
        dismissed = store.dismissed(profile: profile)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            phase = .loaded(try await service.legacyConnections())
        } catch {
            if !Task.isCancelled { phase = .failed }
        }
    }

    func display(in catalog: ConnectCatalog) -> Display {
        switch phase {
        case .idle: return .hidden
        case .failed: return .unreadable(code: Self.failedCode)
        case .loaded(let result):
            if result.isUnreadable { return .unreadable(code: Self.unreadableCode) }
            let rows = LegacyReconnect.rows(result, catalog: catalog, dismissed: dismissed)
            return rows.isEmpty ? .hidden : .rows(rows)
        }
    }

    func dismiss(_ row: LegacyReconnectRow) {
        store.dismiss(row.item.legacySlug, profile: profile)
        dismissed.insert(row.item.legacySlug)
    }
}
