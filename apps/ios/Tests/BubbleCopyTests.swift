#if os(macOS)
import AppKit
import Testing

@testable import Pal

@MainActor
@Suite("Mac bubble copy")
struct BubbleCopyTests {
    private func bubble(_ text: String, selecting ranges: [NSRange]) -> PassiveTextView {
        let view = PassiveTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.textStorage?.setAttributedString(NSAttributedString(string: text))
        view.selectedRanges = ranges.map { NSValue(range: $0) }
        return view
    }

    @Test func copyingASelectionPutsExactlyThatTextOnThePasteboard() {
        let view = bubble("Hermes updated main but the service did not reload", selecting: [NSRange(location: 7, length: 12)])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "updated main")
        #expect(!(pasteboard.types ?? []).contains(.rtf))
    }

    @Test func anEmptySelectionWritesNothing() {
        let view = bubble("Nothing selected here", selecting: [NSRange(location: 3, length: 0)])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(!view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == nil)
    }
}
#endif
