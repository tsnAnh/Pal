import CoreGraphics
import SwiftUI

public enum SetupButtonRole: Sendable {
    case primary
    case secondary
    case quiet
}

public struct SetupFooterMetrics: Equatable, Sendable {
    public let buttonHeight: CGFloat
    public let buttonTextSize: CGFloat
    public let buttonSidePadding: CGFloat
    public let primarySidePadding: CGFloat
    public let backMinimumWidth: CGFloat
    public let primaryMinimumWidth: CGFloat
    public let buttonSpacing: CGFloat
    public let insets: EdgeInsets

    public static let fadeHeight: CGFloat = 24

    public static let mac = SetupFooterMetrics(
        buttonHeight: 38, buttonTextSize: PalTextStyle.rowTitle.size, buttonSidePadding: 22, primarySidePadding: 26,
        backMinimumWidth: 96, primaryMinimumWidth: 160, buttonSpacing: 10,
        insets: EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24)
    )

    public static let phone = SetupFooterMetrics(
        buttonHeight: 52, buttonTextSize: 17, buttonSidePadding: 22, primarySidePadding: 26,
        backMinimumWidth: 96, primaryMinimumWidth: 160, buttonSpacing: 10,
        insets: EdgeInsets(top: 16, leading: 20, bottom: 28, trailing: 20)
    )

    #if os(iOS)
    public static let stacksFullWidthButtons = true
    #else
    public static let stacksFullWidthButtons = false
    #endif

    public static func metrics(stacked: Bool) -> SetupFooterMetrics {
        stacked ? .phone : .mac
    }

    public static func buttons(fillsWidth: Bool) -> SetupFooterMetrics {
        metrics(stacked: fillsWidth && stacksFullWidthButtons)
    }

    public func sidePadding(for role: SetupButtonRole) -> CGFloat {
        role == .primary ? primarySidePadding : buttonSidePadding
    }

    public func minimumWidth(for role: SetupButtonRole) -> CGFloat {
        switch role {
        case .primary: primaryMinimumWidth
        case .secondary: backMinimumWidth
        case .quiet: 0
        }
    }
}

private struct SetupButtonLabelModifier: ViewModifier {
    let metrics: SetupFooterMetrics
    let role: SetupButtonRole
    let fillsWidth: Bool
    @ScaledMetric private var height: CGFloat
    @ScaledMetric private var textSize: CGFloat

    init(metrics: SetupFooterMetrics, role: SetupButtonRole, fillsWidth: Bool) {
        self.metrics = metrics
        self.role = role
        self.fillsWidth = fillsWidth
        _height = ScaledMetric(wrappedValue: metrics.buttonHeight, relativeTo: .body)
        _textSize = ScaledMetric(wrappedValue: metrics.buttonTextSize, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: textSize))
            .padding(.horizontal, metrics.sidePadding(for: role))
            .frame(minWidth: metrics.minimumWidth(for: role), maxWidth: fillsWidth ? .infinity : nil, minHeight: height)
    }
}

public extension View {
    func setupButtonLabel(_ metrics: SetupFooterMetrics, role: SetupButtonRole, fillsWidth: Bool) -> some View {
        modifier(SetupButtonLabelModifier(metrics: metrics, role: role, fillsWidth: fillsWidth))
    }
}
