import Observation
import SwiftUI

@MainActor
@Observable
final class RowHoverState {
    enum Region: Hashable {
        case message
        case bar
    }

    static let hideDelay = Duration.milliseconds(120)

    private(set) var isHovering = false

    @ObservationIgnored private var inside: Set<Region> = []
    @ObservationIgnored private var pendingHide: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func enter(_ region: Region) {
        inside.insert(region)
        pendingHide?.cancel()
        pendingHide = nil
        setHovering(true)
    }

    func exit(_ region: Region) {
        inside.remove(region)
        guard inside.isEmpty, isHovering, pendingHide == nil else { return }
        pendingHide = Task { [weak self, sleep = self.sleep] in
            do { try await sleep(Self.hideDelay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        pendingHide = nil
        guard inside.isEmpty else { return }
        setHovering(false)
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
    }
}

private struct RowHoverKey: EnvironmentKey {
    static let defaultValue: RowHoverState? = nil
}

extension EnvironmentValues {
    var rowHover: RowHoverState? {
        get { self[RowHoverKey.self] }
        set { self[RowHoverKey.self] = newValue }
    }
}
