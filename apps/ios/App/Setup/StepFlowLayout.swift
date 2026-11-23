import PalDesign
import SwiftUI

enum StepFlowLayout {
    case stacked
    case rail
    case stepper

    #if os(iOS)
    init(sizeClass: UserInterfaceSizeClass?) {
        self = sizeClass == .regular ? .rail : .stacked
    }
    #endif

    var showsChecklist: Bool { self == .rail }
    var showsSegments: Bool { self != .rail }
    var fillsWidth: Bool { self == .stacked }
    var keepsLinksInContent: Bool { self == .stepper }

    func footerLayout(at size: DynamicTypeSize) -> StepFlowLayout {
        size.isAccessibilitySize ? .stacked : self
    }

    var contentInsets: EdgeInsets {
        switch self {
        case .stepper:
            EdgeInsets(
                top: StepperMetrics.contentTop, leading: StepperMetrics.contentMargin, bottom: PalMetrics.screenMargin,
                trailing: StepperMetrics.contentMargin
            )
        case .stacked, .rail:
            EdgeInsets(top: PalMetrics.screenMargin, leading: PalMetrics.screenMargin, bottom: PalMetrics.screenMargin, trailing: PalMetrics.screenMargin)
        }
    }
}

enum StepperMetrics {
    static let barMargin: CGFloat = 20
    static let contentMargin: CGFloat = 24
    static let contentTop: CGFloat = 22
    static let logoSize: CGFloat = 28
    static let stepTitleSize: CGFloat = 20
}

private struct StepTitleStyle: ViewModifier {
    let layout: StepFlowLayout

    func body(content: Content) -> some View {
        switch layout {
        case .stepper: content.font(.system(size: StepperMetrics.stepTitleSize, weight: .semibold))
        case .stacked, .rail: content.hermesText(.sheetTitle)
        }
    }
}

extension View {
    func stepTitleStyle(_ layout: StepFlowLayout) -> some View {
        modifier(StepTitleStyle(layout: layout))
    }
}
