import CoreGraphics
import Testing
@testable import PalDesign

private let chatFontSizes: [CGFloat] = [11, 13, 15, 17, 20, 24, 30]

@Suite("An inline link icon is centred on the text's cap height")
struct InlineIconMetricsTests {
    private func iconCentre(iconHeight: CGFloat, offset: CGFloat, textShift: CGFloat) -> CGFloat {
        iconHeight / 2 + offset - textShift
    }

    @Test("the icon centre lands on the middle of the capitals for every font and icon size", arguments: chatFontSizes)
    func centreOnCapitals(fontSize: CGFloat) {
        let line = ChatLineBox(fontSize: fontSize)
        for iconHeight in [fontSize, fontSize * 1.13, fontSize * 1.5] {
            let offset = InlineIconMetrics.baselineOffset(iconHeight: iconHeight, line: line)
            let centre = iconCentre(iconHeight: iconHeight, offset: offset, textShift: line.textBaselineShift)
            #expect(abs(centre - line.capHeight / 2) < 0.001)
        }
    }

    @Test("a taller icon is lowered, a shorter one is never raised past the cap height")
    func direction() {
        #expect(InlineIconMetrics.baselineOffset(iconHeight: 17, capHeight: 10.7, textShift: 0) < 0)
        let small = InlineIconMetrics.baselineOffset(iconHeight: 8, capHeight: 10.7, textShift: 0)
        #expect(small >= 0)
        #expect(8 + small <= 10.7)
    }

    @Test("an icon at least as tall as the capitals is never raised, so it cannot clip above the line", arguments: chatFontSizes)
    func neverRaisedAboveTheLine(fontSize: CGFloat) {
        let line = ChatLineBox(fontSize: fontSize)
        let iconHeight = fontSize * 17 / PalTextStyle.chatBody.size
        let offset = InlineIconMetrics.baselineOffset(iconHeight: iconHeight, capHeight: line.capHeight, textShift: 0)
        #expect(iconHeight >= line.capHeight)
        #expect(offset <= 0)
        #expect(iconHeight + offset >= line.capHeight)
    }

    @Test("the text shift of the line box is carried unchanged into the icon offset")
    func carriesTextShift() {
        let flat = InlineIconMetrics.baselineOffset(iconHeight: 17, capHeight: 10.7, textShift: 0)
        let shifted = InlineIconMetrics.baselineOffset(iconHeight: 17, capHeight: 10.7, textShift: -2)
        #expect(abs((shifted - flat) - -2) < 0.001)
    }

    @Test("the line box shifts the text by minus its baseline offset, except on the macOS 15 layout")
    func lineShift() {
        let line = ChatLineBox(fontSize: 15)
        #if os(macOS)
        if #available(macOS 26, *) {
            #expect(line.textBaselineShift == -line.baselineOffset)
        } else {
            #expect(line.textBaselineShift == 0)
        }
        #else
        #expect(line.textBaselineShift == -line.baselineOffset)
        #endif
    }
}
