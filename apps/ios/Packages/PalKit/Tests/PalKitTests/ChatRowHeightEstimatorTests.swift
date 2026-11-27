import PalChat
import Testing

private let width = 600.0
private let lineHeight = 22.0

@Suite("Chat row height estimator")
struct ChatRowHeightEstimatorTests {
    @Test func theShapeDrivesTheEstimate() {
        let estimator = ChatRowHeightEstimator()
        let short = estimator.estimate(ChatRowShape(kind: .assistant, characters: 40), width: width, lineHeight: lineHeight)
        let long = estimator.estimate(ChatRowShape(kind: .assistant, characters: 2000), width: width, lineHeight: lineHeight)
        let withImage = estimator.estimate(ChatRowShape(kind: .assistant, characters: 40, images: 1), width: width, lineHeight: lineHeight)
        let withFile = estimator.estimate(ChatRowShape(kind: .assistant, characters: 40, files: 1), width: width, lineHeight: lineHeight)
        #expect(long > short)
        #expect(withImage > short)
        #expect(withFile > short)
        #expect(Set([short, long, withImage]).count == 3)
    }

    @Test func noEstimateIsBelowTheFloor() {
        let estimator = ChatRowHeightEstimator()
        for kind in ChatRowShapeKind.allCases {
            #expect(estimator.estimate(ChatRowShape(kind: kind), width: width, lineHeight: 1) >= 24)
        }
    }

    @Test func observingMovesTheScaleTowardTheMeasuredRatio() {
        var estimator = ChatRowHeightEstimator()
        let shape = ChatRowShape(kind: .user, characters: 200)
        let before = estimator.estimate(shape, width: width, lineHeight: lineHeight)
        #expect(estimator.scale(for: .user) == 1)
        estimator.observe(shape, measured: before * 0.5, width: width, lineHeight: lineHeight)
        #expect(abs(estimator.scale(for: .user) - 0.5) < 0.001)
        #expect(estimator.scale(for: .assistant) == 1)
        #expect(estimator.estimate(shape, width: width, lineHeight: lineHeight) < before)
    }

    @Test func theScaleIsClampedToTheRange() {
        var estimator = ChatRowHeightEstimator()
        let shape = ChatRowShape(kind: .assistant, characters: 100)
        estimator.observe(shape, measured: 1_000_000, width: width, lineHeight: lineHeight)
        #expect(estimator.scale(for: .assistant) == ChatRowHeightEstimator.scaleRange.upperBound)
        var small = ChatRowHeightEstimator()
        small.observe(shape, measured: 0.001, width: width, lineHeight: lineHeight)
        #expect(small.scale(for: .assistant) == ChatRowHeightEstimator.scaleRange.lowerBound)
    }

    @Test func onlyTheLastSamplesCount() {
        var estimator = ChatRowHeightEstimator()
        let shape = ChatRowShape(kind: .assistant, characters: 100)
        let base = estimator.estimate(shape, width: width, lineHeight: lineHeight)
        for _ in 0..<ChatRowHeightEstimator.sampleLimit {
            estimator.observe(shape, measured: base * 2, width: width, lineHeight: lineHeight)
        }
        #expect(abs(estimator.scale(for: .assistant) - 2) < 0.001)
        for _ in 0..<ChatRowHeightEstimator.sampleLimit {
            estimator.observe(shape, measured: base * 0.5, width: width, lineHeight: lineHeight)
        }
        #expect(abs(estimator.scale(for: .assistant) - 0.5) < 0.001)
    }

    @Test func nonPositiveInputIsIgnored() {
        var estimator = ChatRowHeightEstimator()
        let shape = ChatRowShape(kind: .user, characters: 50)
        estimator.observe(shape, measured: 0, width: width, lineHeight: lineHeight)
        estimator.observe(shape, measured: -3, width: width, lineHeight: lineHeight)
        estimator.observe(shape, measured: 50, width: 0, lineHeight: lineHeight)
        estimator.observe(shape, measured: 50, width: width, lineHeight: 0)
        #expect(estimator == ChatRowHeightEstimator())
    }

    @Test func aCalibratedUserEstimateLandsNearTheMeasuredHeight() {
        var estimator = ChatRowHeightEstimator()
        let shape = ChatRowShape(kind: .user, characters: 200)
        for _ in 0..<3 {
            estimator.observe(shape, measured: 74, width: width, lineHeight: lineHeight)
        }
        let estimate = estimator.estimate(shape, width: width, lineHeight: lineHeight)
        #expect(abs(estimate - 74) / 74 <= 0.25)
    }
}
