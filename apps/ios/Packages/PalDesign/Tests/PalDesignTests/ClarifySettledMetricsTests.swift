import CoreGraphics
import Testing

@testable import PalDesign

@Suite("Settled clarify card metrics")
struct ClarifySettledMetricsTests {
    private let titleLine: CGFloat = 22
    private let rowLine: CGFloat = 22

    private func height(_ entries: [ClarifySettledMetrics.Entry]) -> CGFloat {
        ClarifySettledMetrics.height(of: entries, titleLineHeight: titleLine, rowLineHeight: rowLine)
    }

    @Test("one title line and one chosen row is the padding plus the two lines and the gap between them")
    func single() {
        let expected = 2 * ClarifySettledMetrics.surfacePadding + titleLine + ClarifySettledMetrics.titleToRows + rowLine
        #expect(height([.init(titleLines: 1, rowLines: [1])]) == expected)
    }

    @Test("every extra title line, chosen row and wrapped row line adds its own height")
    func grows() {
        let base = height([.init(titleLines: 1, rowLines: [1])])
        #expect(height([.init(titleLines: 2, rowLines: [1])]) == base + titleLine)
        #expect(height([.init(titleLines: 1, rowLines: [2])]) == base + rowLine)
        #expect(height([.init(titleLines: 1, rowLines: [1, 1])]) == base + rowLine + ClarifySettledMetrics.rowSpacing)
    }

    @Test("a second question adds its block and one entry gap")
    func twoQuestions() {
        let one = height([.init(titleLines: 1, rowLines: [1])])
        let two = height([.init(titleLines: 1, rowLines: [1]), .init(titleLines: 1, rowLines: [1])])
        #expect(two == one + (one - 2 * ClarifySettledMetrics.surfacePadding) + ClarifySettledMetrics.entrySpacing)
    }

    @Test("an entry with no row is the title alone")
    func skipped() {
        #expect(height([.init(titleLines: 1, rowLines: [])]) == height([.init(titleLines: 1, rowLines: [1])]) - rowLine)
    }

    @Test("text widths leave the padding and the checkmark column")
    func widths() {
        #expect(ClarifySettledMetrics.titleWidth(cardWidth: 300) == 268)
        #expect(ClarifySettledMetrics.rowTextWidth(cardWidth: 300) == 238)
        #expect(ClarifySettledMetrics.rowTextWidth(cardWidth: 10) == 0)
    }
}
