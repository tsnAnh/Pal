import CoreGraphics
@testable import PalDesign
import Testing

@Suite("Setup footer metrics")
struct SetupFooterMetricsTests {
    @Test func theMacFooterIsThirtyEightHighWithFifteenPointText() {
        let mac = SetupFooterMetrics.mac
        #expect(mac.buttonHeight == 38)
        #expect(mac.buttonTextSize == 15)
        #expect(mac.buttonTextSize == PalTextStyle.rowTitle.size)
        #expect(mac.buttonSidePadding == 22)
        #expect(mac.primarySidePadding == 26)
        #expect(mac.backMinimumWidth == 96)
        #expect(mac.primaryMinimumWidth == 160)
    }

    @Test func theMacFooterSitsOnTheTwentyFourPointContentMargin() {
        let insets = SetupFooterMetrics.mac.insets
        #expect(insets.leading == 24)
        #expect(insets.trailing == 24)
        #expect(insets.top == 16)
        #expect(insets.bottom == 20)
    }

    @Test func thePhoneFooterIsFiftyTwoHighWithSeventeenPointText() {
        let phone = SetupFooterMetrics.phone
        #expect(phone.buttonHeight == 52)
        #expect(phone.buttonTextSize == 17)
        #expect(phone.insets.leading == 20)
        #expect(phone.insets.trailing == 20)
        #expect(phone.insets.bottom == 28)
    }

    @Test func aStackedFooterTakesPhoneSizesAndARowFooterTakesMacSizes() {
        #expect(SetupFooterMetrics.metrics(stacked: true) == .phone)
        #expect(SetupFooterMetrics.metrics(stacked: false) == .mac)
    }

    @Test func onlyAFullWidthButtonOnAPhoneStacksAtPhoneSize() {
        #expect(SetupFooterMetrics.buttons(fillsWidth: false) == .mac)
        #if os(macOS)
        #expect(!SetupFooterMetrics.stacksFullWidthButtons)
        #expect(SetupFooterMetrics.buttons(fillsWidth: true) == .mac)
        #else
        #expect(SetupFooterMetrics.stacksFullWidthButtons)
        #expect(SetupFooterMetrics.buttons(fillsWidth: true) == .phone)
        #endif
    }

    @Test func theRolesChoosePaddingAndMinimumWidth() {
        let mac = SetupFooterMetrics.mac
        #expect(mac.sidePadding(for: .primary) == 26)
        #expect(mac.sidePadding(for: .secondary) == 22)
        #expect(mac.sidePadding(for: .quiet) == 22)
        #expect(mac.minimumWidth(for: .primary) == 160)
        #expect(mac.minimumWidth(for: .secondary) == 96)
        #expect(mac.minimumWidth(for: .quiet) == 0)
    }
}
