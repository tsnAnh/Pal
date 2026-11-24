import Foundation
import PalChat
import Testing

private func geo(offset: Double, content: Double) -> ChatScrollGeometry {
    ChatScrollGeometry(
        offsetY: offset, contentHeight: content, containerHeight: 983, containerWidth: 900,
        insetTop: 0, insetBottom: 92
    )
}

@Suite("Chat first layout fixture")
struct ChatFirstLayoutFixtureTests {
    @Test func theRecordedOpenOvershootsAndSettlesSlowly() {
        let contents = [147_352.0, 62_022, 61_355, 60_257, 35_647, 35_404, 35_809]
        let offsets = [145_331.0, 60_001, 34_609]
        let times = [0, 5, 30, 60, 3003, 3300, 3600]
        var meter = ChatOpenSettleMeter()
        for (index, content) in contents.enumerated() {
            let offset = index < offsets.count ? offsets[index] : content - 983
            meter.geometry(geo(offset: offset, content: content), atMilliseconds: times[index])
        }
        let report = meter.report(atMilliseconds: 3600)
        #expect(report.overshootFactor > 4)
        #expect(report.settleMilliseconds >= 3000)
        #expect(report.firstContent == 147_352)
        #expect(report.settledContent == 35_809)
    }

    @Test func thePastEndSampleIsMeasured() {
        let sample = geo(offset: 16_797, content: 4_602)
        #expect(sample.overshoot == 16_797 + 983 - 4_602)
        var meter = ChatOpenSettleMeter()
        meter.geometry(sample, atMilliseconds: 0)
        #expect(meter.report(atMilliseconds: 0).maxPastEnd > 8)
    }

    @Test func persistedExactHeightsPredictTheSettledContent() {
        let rows = (0..<161).map { "r\($0)" }
        var tail = ChatTail()
        let plan = tail.plan(ids: rows, viewport: 983, height: { _ in 222 })
        let rendered = Double(rows.count - plan.start) * 222
        let predicted = rendered + plan.hiddenHeight
        let settled = 161.0 * 222
        #expect(predicted == settled)
        #expect(predicted <= settled * 1.3)
    }

    @Test func aCalibratedEstimatorStaysNearTheMeasuredHeight() {
        var estimator = ChatRowHeightEstimator()
        let shape = ChatRowShape(kind: .assistant, characters: 600)
        for _ in 0..<12 {
            estimator.observe(shape, measured: 222, width: 900, lineHeight: 22)
        }
        let estimate = estimator.estimate(shape, width: 900, lineHeight: 22)
        #expect(abs(estimate - 222) / 222 <= 0.25)
        let total = Double(161) * estimate
        #expect(total <= 161.0 * 222 * 1.3)
    }

    @Test func aStableOpenReportsNoOvershoot() {
        var meter = ChatOpenSettleMeter()
        meter.geometry(geo(offset: 35_742 - 983, content: 35_742), atMilliseconds: 0)
        #expect(!meter.isSettled)
        meter.geometry(geo(offset: 35_742 - 983, content: 35_742), atMilliseconds: 600)
        let report = meter.report(atMilliseconds: 600)
        #expect(report.overshootFactor == 1)
        #expect(report.settleMilliseconds == 0)
        #expect(meter.isSettled)
        #expect(report.rowsHitZero == 0)
    }

    @Test func rowsDroppingToZeroAfterHavingRowsIsCounted() {
        var meter = ChatOpenSettleMeter()
        meter.rows(count: 117)
        meter.rows(count: 0)
        #expect(meter.report(atMilliseconds: 0).rowsHitZero == 1)
        meter.rows(count: 0)
        #expect(meter.report(atMilliseconds: 0).rowsHitZero == 1)
    }
}
