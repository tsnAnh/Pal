import Foundation
import PalDiagnostics
import Testing

struct HitchCounterTests {
    @Test func classifiesSyntheticFrameDurations() {
        var counter = HitchCounter()
        #expect(counter.record(frameMs: 16) == .smooth)
        #expect(counter.record(frameMs: 16.7) == .smooth)
        #expect(counter.record(frameMs: 20) == .hitch)
        #expect(counter.record(frameMs: 33) == .hitch)
        #expect(counter.record(frameMs: 40) == .severe)
        #expect(counter.frames == 5)
        #expect(counter.hitches == 3)
        #expect(counter.severeHitches == 1)
        #expect(counter.worstFrameMs == 40)
    }

    @Test func sumsTimeAboveTheHitchThreshold() {
        var counter = HitchCounter()
        counter.record(frameMs: 10)
        counter.record(frameMs: 26.7)
        counter.record(frameMs: 36.7)
        #expect(abs(counter.hitchMs - 30) < 0.000_001)
    }

    @Test func reportEncodesAsTheDocumentedJSON() throws {
        var counter = HitchCounter()
        counter.record(frameMs: 16)
        counter.record(frameMs: 20)
        counter.record(frameMs: 40)
        let report = counter.report(platform: "macOS", startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 12.5)
        let object = try #require(JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        #expect(object["platform"] as? String == "macOS")
        #expect(object["frames"] as? Int == 3)
        #expect(object["hitches"] as? Int == 2)
        #expect(object["severeHitches"] as? Int == 1)
        #expect(object["worstFrameMs"] as? Double == 40)
        #expect(object["durationSeconds"] as? Double == 12.5)
        let thresholds = try #require(object["thresholdsMs"] as? [String: Double])
        #expect(thresholds == ["hitch": 16.7, "severe": 33.0])
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
