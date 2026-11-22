import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import PalDesign

private let benchKey = "PAL_AVATAR_BENCH"
private let benchOutKey = "PAL_AVATAR_BENCH_OUT"
private let frameCount = 300
private let runs = 5

private enum Sequence: String, CaseIterable {
    case turning
    case working
    case settled

    func poses(restTilt: Double) -> [(AvatarPose, AvatarLook)] {
        let seed = LoadingSequence.seed(for: "bench")
        return (0..<frameCount).map { index in
            let t = Double(index)
            switch self {
            case .turning:
                let pose = AvatarPose.facing.with { $0.yaw = 30 * sin(t * 0.05); $0.pitch = 12 * cos(t * 0.037) }
                return (pose, .zero)
            case .working:
                let pose = AvatarMotion.pose(.work, at: t / 30, seed: seed)
                return (pose, AvatarLook(amount: 0.8, x: sin(t * 0.1), y: cos(t * 0.13)))
            case .settled:
                return (AvatarPose.facing.with { $0.yaw = 12 }, AvatarLook(amount: 0.5, x: 0.2, y: -0.1))
            }
        }
    }
}

private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

@Suite("Solid avatar benchmark", .serialized, .enabled(if: ProcessInfo.processInfo.environment[benchKey] == "1"))
@MainActor
struct SolidFrameBenchmark {
    private let avatar = solid("blobatar:k7q2m9x0:organic")

    private func milliseconds(_ work: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(work).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment[benchOutKey] else { return }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("300 frames of the avatar drawn through the canvas")
    func drawnFrames() {
        for sequence in Sequence.allCases {
            for size in [CGFloat(26), 201] {
                let poses = sequence.poses(restTilt: avatar.restTilt)
                var samples: [Double] = []
                for _ in 0..<runs {
                    samples.append(milliseconds {
                        for (pose, look) in poses {
                            let renderer = ImageRenderer(content: SolidCanvas(
                                solid: avatar, pose: pose, size: size, look: look, outline: nil, reduceMotion: false
                            ))
                            renderer.scale = 2
                            _ = renderer.cgImage
                        }
                    })
                }
                report(String(
                    format: "BENCH canvas %@ %dpt median %.1f ms (%.2f ms/frame) runs %@",
                    sequence.rawValue, Int(size), median(samples), median(samples) / Double(frameCount),
                    samples.map { String(format: "%.0f", $0) }.joined(separator: ",")
                ))
            }
        }
    }

    @Test("300 frames of geometry only: detail lookup, pose, silhouette and eyes")
    func geometryFrames() {
        for sequence in Sequence.allCases {
            for size in [CGFloat(26), 201] {
                let poses = sequence.poses(restTilt: avatar.restTilt)
                let inset = (size * 0.3).rounded()
                var samples: [Double] = []
                var sink = 0.0
                for _ in 0..<runs {
                    samples.append(milliseconds {
                        for (pose, look) in poses {
                            let detailed = avatar.detailed(for: size)
                            let resolved = SolidPose.resolve(pose: pose, look: look, restTilt: detailed.restTilt, reduceMotion: false)
                            let frame = SolidFrame.make(solid: detailed, pose: resolved, projection: detailed.projection(size: size, inset: inset))
                            sink += Double(frame.eyes.count)
                        }
                    })
                }
                report(String(
                    format: "BENCH geometry %@ %dpt median %.1f ms (%.3f ms/frame) runs %@ sink %.0f",
                    sequence.rawValue, Int(size), median(samples), median(samples) / Double(frameCount),
                    samples.map { String(format: "%.1f", $0) }.joined(separator: ","), sink
                ))
            }
        }
    }
}
