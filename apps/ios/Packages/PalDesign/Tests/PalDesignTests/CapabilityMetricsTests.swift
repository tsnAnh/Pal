import CoreGraphics
@testable import PalDesign
import SwiftUI
import Testing

@Suite("Capability metrics")
struct CapabilityMetricsTests {
    @Test func theMacSetKeyCapsuleIsThirtyTwoHighWithFourteenPointText() {
        #expect(CapabilityMetrics.mac.setKeyHeight == 32)
        #expect(CapabilityMetrics.mac.setKeyTextSize == 14)
    }

    @Test func thePhoneSetKeyCapsuleIsThirtySixHighWithFifteenPointText() {
        #expect(CapabilityMetrics.phone.setKeyHeight == 36)
        #expect(CapabilityMetrics.phone.setKeyTextSize == 15)
    }

    @Test func theAddButtonIsFortySixHighOnMacAndFiftyTwoOnPhone() {
        #expect(CapabilityMetrics.mac.addButtonHeight == 46)
        #expect(CapabilityMetrics.mac.addButtonTextSize == 15)
        #expect(CapabilityMetrics.phone.addButtonHeight == 52)
        #expect(CapabilityMetrics.phone.addButtonTextSize == 17)
        #expect(CapabilityMetrics.phone.addButtonHeight == SetupFooterMetrics.phone.buttonHeight)
    }

    @Test func theRowTokensMatchTheApprovedDesign() {
        #expect(CapabilityMetrics.onRowMinHeight == 52)
        #expect(CapabilityMetrics.limitedRowMinHeight == 76)
        #expect(CapabilityMetrics.statusIcon == 24)
        #expect(CapabilityMetrics.iconToTextGap == 14)
        #expect(CapabilityMetrics.textIndent == 38)
        #expect(CapabilityMetrics.setKeySidePadding == 16)
        #expect(CapabilityMetrics.tapTarget == 44)
        #expect(CapabilityMetrics.addIconSize == 18)
        #expect(CapabilityMetrics.addIconGap == 8)
        #expect(CapabilityMetrics.addTopGap == 14)
        #expect(CapabilityMetrics.reasonSize == 13)
        #expect(CapabilityMetrics.reasonLineLimit == 3)
        #expect(CapabilityMetrics.groupCaptionSize == 12)
        #expect(CapabilityMetrics.groupCaptionLeadingInset == 6)
        #expect(CapabilityMetrics.groupCaptionTopGap == 14)
        #expect(CapabilityMetrics.groupCaptionBottomGap == 6)
    }

    @Test func aRowWithAReasonOrAnActionTakesTheTallerMinimum() {
        #expect(CapabilityMetrics.rowMinHeight(hasDetail: false) == 52)
        #expect(CapabilityMetrics.rowMinHeight(hasDetail: true) == 76)
    }

    @Test func theConnectRowTokensStayAsTheyWere() {
        #expect(ConnectRowMetrics.titleSize == 16)
        #expect(ConnectRowMetrics.captionSize == 12.5)
        #expect(ConnectRowMetrics.tileSize == 40)
    }

    @Test func onlyACompactTouchWidthTakesPhoneSizes() {
        #expect(CapabilityMetrics.metrics(sizeClass: .regular) == .mac)
        #expect(CapabilityMetrics.metrics(sizeClass: nil) == .mac)
        #if os(macOS)
        #expect(CapabilityMetrics.metrics(sizeClass: .compact) == .mac)
        #else
        #expect(CapabilityMetrics.metrics(sizeClass: .compact) == .phone)
        #endif
    }

    @Test func theTapAreaReachesFortyFourPointsOnTouchOnly() {
        #if os(macOS)
        #expect(CapabilityMetrics.hitOutset(visualHeight: 32) == 0)
        #else
        #expect(CapabilityMetrics.hitOutset(visualHeight: 36) == 4)
        #expect(CapabilityMetrics.hitOutset(visualHeight: 52) == 0)
        #endif
    }
}
