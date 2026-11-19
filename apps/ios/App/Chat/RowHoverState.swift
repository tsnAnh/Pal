import Observation
import SwiftUI

@MainActor
@Observable
final class RowHoverState {
    private(set) var isHovering = false

    func setHovering(_ hovering: Bool) {
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
