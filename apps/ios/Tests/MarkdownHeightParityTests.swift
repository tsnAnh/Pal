#if os(macOS)
import AppKit
import PalChat
import SwiftUI
import Testing

@testable import HermesBots

@MainActor
@Suite("Markdown height parity")
struct MarkdownHeightParityTests {
    private static let width: CGFloat = 360

    private static let documents = [
        "One short line.",
        "A paragraph long enough to wrap across several lines so the line spacing is exercised at least twice in a narrow column.",
        "First paragraph.\n\nSecond paragraph with **bold** and `code` and a [link](https://example.com).",
        "# Heading\n\nBody under the heading.\n\n## Second heading\n\nMore body text.",
        "- one\n- two\n- three",
        "1. first\n2. second\n   - nested a\n   - nested b\n3. third",
        "Intro:\n\n- item one\n- item two\n\nOutro paragraph that wraps across more than one line in this narrow column for sure.",
    ]

    private func segment(_ source: String) throws -> TextSegment {
        let segments = MarkdownDocument(parsing: source).messageSegments
        guard case .text(let text) = try #require(segments.first) else { throw ParityError.noText }
        return text
    }

    private func height<Content: View>(of content: Content) -> CGFloat {
        let host = NSHostingView(rootView: content)
        return host.sizeThatFits(ProposedViewSize(width: Self.width, height: nil)).height
    }

    @Test func theTextAndTheTextViewPathsReportTheSameHeight() throws {
        for source in Self.documents {
            let text = try segment(source)
            let streaming = height(of: MarkdownView(segment: text, wholeBubbleSelection: false, highlight: "", isCurrentMatch: false))
            let selectable = height(of: MarkdownView(segment: text, wholeBubbleSelection: true, highlight: "", isCurrentMatch: false))
            #expect(abs(streaming - selectable) <= 1, "\(source): text path \(streaming), text view path \(selectable)")
        }
    }

    private enum ParityError: Error {
        case noText
    }
}
#endif
