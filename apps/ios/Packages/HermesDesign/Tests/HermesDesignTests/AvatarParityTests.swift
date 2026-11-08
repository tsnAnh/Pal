import Foundation
import SwiftUI
import Testing
@testable import HermesDesign

private let matrix = ParityMatrix.shared

private let maxDifferingFraction = 0.005
private let channelTolerance = 40

struct ParityScore: Sendable {
    var id: String
    var group: String
    var differingFraction: Double
    var meanDifference: Double
    var maxDifference: Int
}

@MainActor
private func score(_ testCase: ParityMatrix.Case) throws -> ParityScore {
    let spec = BotAvatarSpec(name: testCase.name, uiMeta: testCase.uiMeta, photo: nil)
    let size = CGFloat(matrix.size)
    let renderer = ImageRenderer(
        content: BotAvatarView(spec: spec, size: size, mood: AvatarMood(rawValue: testCase.mood) ?? .idle, animated: false)
            .environment(\.colorScheme, .dark)
    )
    renderer.scale = 1
    guard let rendered = renderer.cgImage else { throw ParityError.renderFailed(testCase.id) }
    let expected = try PixelBuffer(png: ParityMatrix.pngURL(try #require(testCase.png)), side: matrix.size)
    let actual = try PixelBuffer(image: rendered, side: matrix.size)
    return expected.compare(to: actual, tolerance: channelTolerance, id: testCase.id, group: testCase.group)
}

@Suite("Rendered avatars match the desktop pixel for pixel", .serialized)
@MainActor
struct AvatarParityTests {
    @Test("every case stays inside the pixel budget", arguments: matrix.cases.filter(\.render))
    func casesMatch(testCase: ParityMatrix.Case) throws {
        let result = try score(testCase)
        #expect(
            result.differingFraction <= maxDifferingFraction,
            "\(testCase.id): \(String(format: "%.3f", result.differingFraction * 100))% pixels differ, max \(result.maxDifference)"
        )
    }

    @Test("parity report per group")
    func report() throws {
        var byGroup: [String: [ParityScore]] = [:]
        for testCase in matrix.cases where testCase.render {
            byGroup[testCase.group, default: []].append(try score(testCase))
        }
        var lines = ["group | cases | worst % differing | mean % differing | worst max channel diff | mean abs diff"]
        for group in byGroup.keys.sorted() {
            let scores = byGroup[group] ?? []
            let worst = scores.map(\.differingFraction).max() ?? 0
            let mean = scores.map(\.differingFraction).reduce(0, +) / Double(scores.count)
            let worstMax = scores.map(\.maxDifference).max() ?? 0
            let meanDiff = scores.map(\.meanDifference).reduce(0, +) / Double(scores.count)
            lines.append(String(format: "%@ | %d | %.3f | %.3f | %d | %.4f", group, scores.count, worst * 100, mean * 100, worstMax, meanDiff))
        }
        let worstCase = byGroup.values.flatMap { $0 }.max { $0.differingFraction < $1.differingFraction }
        lines.append("worst case: \(worstCase?.id ?? "-") \(String(format: "%.3f", (worstCase?.differingFraction ?? 0) * 100))%")
        print("PARITY REPORT\n" + lines.joined(separator: "\n"))
        if let path = ProcessInfo.processInfo.environment["AVATAR_PARITY_REPORT"] {
            try lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Test("blank or mismatched renders cannot pass")
    func negativeControl() throws {
        let cases = matrix.cases.filter(\.render)
        let first = try #require(cases.first { $0.id == "blob-kinds-round-s1" })
        let other = try #require(cases.first { $0.id == "classic-pill-green" })
        let mismatch = try PixelBuffer(png: ParityMatrix.pngURL(try #require(first.png)), side: matrix.size)
            .compare(
                to: PixelBuffer(png: ParityMatrix.pngURL(try #require(other.png)), side: matrix.size),
                tolerance: channelTolerance, id: "control", group: "control"
            )
        #expect(mismatch.differingFraction > maxDifferingFraction * 2)
    }
}
