import Foundation
import PalDiagnostics
import Testing

struct HitchCounterTests {
    private static let sixtyHz = 1000.0 / 60
    private static let oneTwentyHz = 1000.0 / 120

    @Test func aSixtyHzFrameIsAHitchOnA120HzDisplay() {
        var counter = HitchCounter()
        #expect(counter.record(frameMs: 16.7, budgetMs: Self.oneTwentyHz) == .hitch)
        #expect(counter.hitches == 1)
    }

    @Test func aSixtyHzFrameIsSmoothOnASixtyHzDisplay() {
        var counter = HitchCounter()
        #expect(counter.record(frameMs: 16.7, budgetMs: Self.sixtyHz) == .smooth)
        #expect(counter.record(frameMs: 20, budgetMs: Self.sixtyHz) == .smooth)
        #expect(counter.record(frameMs: 26, budgetMs: Self.sixtyHz) == .hitch)
        #expect(counter.hitches == 1)
    }

    @Test func aSingleBudgetMissStaysSmoothAtEveryRefreshRate() {
        var counter = HitchCounter()
        #expect(counter.record(frameMs: Self.oneTwentyHz, budgetMs: Self.oneTwentyHz) == .smooth)
        #expect(counter.record(frameMs: 12, budgetMs: Self.oneTwentyHz) == .smooth)
        #expect(counter.hitches == 0)
    }

    @Test func severeAndLongTiersStayAbsolute() {
        var counter = HitchCounter()
        #expect(counter.record(frameMs: 33, budgetMs: Self.oneTwentyHz) == .hitch)
        #expect(counter.record(frameMs: 40, budgetMs: Self.oneTwentyHz) == .severe)
        #expect(counter.record(frameMs: 40, budgetMs: Self.sixtyHz) == .severe)
        #expect(counter.record(frameMs: 547, budgetMs: Self.sixtyHz, atSeconds: 42.5) == .long)
        #expect(counter.frames == 4)
        #expect(counter.hitches == 4)
        #expect(counter.severeHitches == 3)
        #expect(counter.worstFrameMs == 547)
        #expect(counter.longHitchCount == 1)
        #expect(counter.longest == [LongHitch(atSeconds: 42.5, ms: 547)])
    }

    @Test func keepsOnlyTheTenLongestSortedWorstFirst() {
        var counter = HitchCounter()
        for index in 1...15 { counter.record(frameMs: 100 + Double(index) * 10, budgetMs: Self.sixtyHz, atSeconds: Double(index)) }
        counter.record(frameMs: 50, budgetMs: Self.sixtyHz, atSeconds: 99)
        #expect(counter.longHitchCount == 15)
        #expect(counter.longest.count == 10)
        #expect(counter.longest.first == LongHitch(atSeconds: 15, ms: 250))
        #expect(counter.longest.last == LongHitch(atSeconds: 6, ms: 160))
        #expect(counter.longest.map(\.ms) == counter.longest.map(\.ms).sorted(by: >))
    }

    @Test func sumsTimeAboveTheFrameBudget() {
        var counter = HitchCounter()
        counter.record(frameMs: 10, budgetMs: Self.sixtyHz)
        counter.record(frameMs: 26.7, budgetMs: 16.7)
        counter.record(frameMs: 36.7, budgetMs: 16.7)
        counter.record(frameMs: 16.7, budgetMs: 8.3)
        #expect(abs(counter.hitchMs - 38.4) < 0.000_001)
    }

    @Test func aMissingBudgetFallsBackToSixtyHz() {
        var counter = HitchCounter()
        #expect(counter.record(frameMs: 20, budgetMs: 0) == .smooth)
        #expect(counter.record(frameMs: 26, budgetMs: -1) == .hitch)
        #expect(counter.budgetMs == HitchCounter.defaultBudgetMs)
    }

    @Test func reportRecordsTheSmallestBudgetSeen() {
        var counter = HitchCounter()
        counter.record(frameMs: 8.3, budgetMs: Self.sixtyHz)
        counter.record(frameMs: 8.3, budgetMs: Self.oneTwentyHz)
        counter.record(frameMs: 8.3, budgetMs: Self.sixtyHz)
        let report = counter.report(platform: "macOS", startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 1)
        #expect(abs(report.budgetMs - Self.oneTwentyHz) < 0.000_001)
        #expect(abs(report.thresholdsMs.hitch - Self.oneTwentyHz * 1.5) < 0.000_001)
    }

    @Test func reportCarriesTheLongestHitchesWithoutAnyContent() throws {
        var counter = HitchCounter()
        counter.record(frameMs: 547, budgetMs: Self.oneTwentyHz, atSeconds: 42.5)
        counter.record(frameMs: 120, budgetMs: Self.oneTwentyHz, atSeconds: 7.25)
        let report = counter.report(platform: "macOS", startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 60)
        let object = try #require(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        #expect(object["longHitchThresholdMs"] as? Double == 100)
        #expect(object["longHitchCount"] as? Int == 2)
        let listed = try #require(object["longHitches"] as? [[String: Double]])
        #expect(listed == [["atSeconds": 42.5, "ms": 547], ["atSeconds": 7.25, "ms": 120]])
        #expect(Set(object.keys) == [
            "schema", "platform", "startedAt", "durationSeconds", "frames", "hitches", "severeHitches", "worstFrameMs",
            "hitchMs", "budgetMs", "thresholdsMs", "longHitchThresholdMs", "longHitchCount", "longHitches",
        ])
    }

    @Test func reportEncodesAsTheDocumentedJSON() throws {
        var counter = HitchCounter()
        counter.record(frameMs: 8.3, budgetMs: 8.0)
        counter.record(frameMs: 20, budgetMs: 8.0)
        counter.record(frameMs: 40, budgetMs: 8.0)
        let report = counter.report(platform: "macOS", startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 12.5)
        let object = try #require(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        #expect(object["schema"] as? Int == 2)
        #expect(object["platform"] as? String == "macOS")
        #expect(object["frames"] as? Int == 3)
        #expect(object["hitches"] as? Int == 2)
        #expect(object["severeHitches"] as? Int == 1)
        #expect(object["worstFrameMs"] as? Double == 40)
        #expect(object["durationSeconds"] as? Double == 12.5)
        #expect(object["budgetMs"] as? Double == 8.0)
        let thresholds = try #require(object["thresholdsMs"] as? [String: Double])
        #expect(thresholds == ["hitch": 12.0, "severe": 33.0])
        let decoded = try JSONDecoder().decode(HitchReport.self, from: report.jsonData())
        #expect(decoded == report)
    }

    @Test func staysOffUnlessRequested() throws {
        let defaults = try #require(UserDefaults(suiteName: "hitch-\(UUID().uuidString)"))
        #expect(!PalPerf.isRequested(environment: [:], defaults: defaults))
        #expect(!PalPerf.isRequested(environment: ["PAL_PERF": "0"], defaults: defaults))
        #expect(PalPerf.isRequested(environment: ["PAL_PERF": "1"], defaults: defaults))
        defaults.set(true, forKey: PalPerf.defaultsKey)
        #expect(PalPerf.isRequested(environment: [:], defaults: defaults))
    }
}
