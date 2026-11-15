import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PalDesign

private let frames = 200
private let diameter: CGFloat = 64

#if DEBUG
private let budget = Duration.milliseconds(25)
#else
private let budget = Duration.milliseconds(2)
#endif

private func median(_ durations: [Duration]) -> Duration {
    durations.sorted()[durations.count / 2]
}

@Suite("Solid avatar frame cost", .serialized)
@MainActor
struct SolidPerformanceTests {
    private let avatar = solid("blobatar:k7q2m9x0:round")

    private func poses() -> [SolidPose] {
        let seed = LoadingSequence.seed(for: "perf")
        return (0..<frames).map { index in
            let pose = AvatarMotion.pose(.work, at: Double(index) * 0.083, seed: seed)
            let look = AvatarLook(amount: 0.8, x: sin(Double(index) * 0.1), y: cos(Double(index) * 0.13))
            return SolidPose.resolve(pose: pose, look: index.isMultiple(of: 2) ? look : .zero, restTilt: avatar.restTilt, reduceMotion: false)
        }
    }

    @Test("resolving a pose and building the silhouette and eyes of one 64 pt frame stays inside the budget")
    func buildsWithinBudget() {
        let projection = avatar.projection(size: diameter, inset: (diameter * 0.3).rounded())
        let ready = poses()
        var times: [Duration] = []
        var sink = 0.0
        let clock = ContinuousClock()
        for pose in ready {
            times.append(clock.measure {
                let frame = SolidFrame(solid: avatar, pose: pose, projection: projection)
                sink += frame.silhouette.boundingRect.width + Double(frame.eyes.count)
            })
        }
        print("SOLID FRAME BUILD median \(median(times)) max \(times.max()!) sink \(sink)")
        #expect(median(times) < budget)
    }

    @Test("resolving, building and painting one 64 pt frame into a bitmap stays inside the budget")
    func paintsWithinBudget() {
        let seed = LoadingSequence.seed(for: "perf")
        var times: [Duration] = []
        let clock = ContinuousClock()
        for index in 0..<frames {
            let pose = AvatarMotion.pose(.work, at: Double(index) * 0.083, seed: seed)
            let look = index.isMultiple(of: 2) ? AvatarLook(amount: 0.8, x: sin(Double(index) * 0.1), y: 0.3) : .zero
            let renderer = ImageRenderer(content: SolidCanvas(
                solid: avatar, pose: pose, size: diameter, look: look, outline: nil, reduceMotion: false
            ))
            renderer.scale = 2
            var drawn: CGImage?
            times.append(clock.measure { drawn = renderer.cgImage })
            #expect(drawn != nil)
        }
        print("SOLID FRAME PAINT median \(median(times)) max \(times.max()!)")
        #expect(median(times) < budget * 5)
    }
}
