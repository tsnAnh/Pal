import SwiftUI

public struct SheetBottomButton: View {
    private let title: String
    private let isBusy: Bool
    private let isEnabled: Bool
    private let accessibilityIdentifier: String
    private let action: () -> Void

    public init(_ title: String, isBusy: Bool, isEnabled: Bool, accessibilityIdentifier: String, action: @escaping () -> Void) {
        self.title = title
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy { ProgressView() }
                Text(title)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassButtonStyle(prominent: true)
        .frame(height: PalMetrics.createButtonHeight)
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

public extension View {
    func sheetBottomAction<Action: View>(keyboardUp: Bool, @ViewBuilder _ action: () -> Action) -> some View {
        safeAreaInset(edge: .bottom) {
            action()
                .padding(.horizontal, PalMetrics.screenMargin)
                .padding(.bottom, keyboardUp ? PalMetrics.screenMargin : 0)
        }
    }
}
