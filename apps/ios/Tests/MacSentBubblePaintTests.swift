#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import Pal

@MainActor
@Suite("Mac sent bubble paint", .serialized)
struct MacSentBubblePaintTests {
    private static let pane = CGSize(width: 420, height: 160)
    private static let settled = Duration.milliseconds(600)

    @Test("a sent message paints at full strength", arguments: [
        (BubbleDelivery.sending, Duration.zero),
        (BubbleDelivery.failed(submissionID: "s1"), Duration.milliseconds(600)),
    ])
    func paintsAtFullStrength(delivery: BubbleDelivery, wait: Duration) async throws {
        let reference = try await pixels(.sent, after: Self.settled)
        let background = try #require(reference.first)
        let fill = try #require(
            Dictionary(reference.filter { $0 != background }.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }
        )
        let painted = try await pixels(delivery, after: wait).count { $0 == fill.key }
        #expect(Double(painted) >= Double(fill.value) * 0.98, "\(painted) of \(fill.value) bubble pixels at full strength")
    }

    private func pixels(_ delivery: BubbleDelivery, after wait: Duration) async throws -> [UInt32] {
        let bubble = UserBubble(
            text: "see it?", delivery: delivery, accent: nil, highlight: "", isCurrentMatch: false, retry: { _ in }
        )
        let host = MacChatBenchHost(root: bubble.frame(width: Self.pane.width, height: Self.pane.height), size: Self.pane)
        defer { host.close() }
        host.settle()
        try await Task.sleep(for: wait)
        let view = host.view
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.bitmapData)
        return (0..<rep.pixelsHigh).flatMap { row in
            (0..<rep.pixelsWide).map { column in
                data.advanced(by: row * rep.bytesPerRow + column * rep.bitsPerPixel / 8)
                    .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            }
        }
    }
}
#endif
