#if os(macOS)
import AppKit
import Testing

@testable import Pal

@MainActor
@Suite("Passive text view scrolling")
struct PassiveTextViewScrollTests {
    private struct Rig {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: PassiveTextView
    }

    private func rig() -> Rig {
        let textView = PassiveTextView(frame: NSRect(x: 0, y: 1_000, width: 300, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 2_000))
        document.addSubview(textView)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scrollView.documentView = document
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        return Rig(window: window, scrollView: scrollView, textView: textView)
    }

    @Test func aTextViewThatIsNotBeingUsedNeverScrollsTheTranscript() {
        let rig = rig()
        let before = rig.scrollView.contentView.bounds.origin

        rig.textView.scroll(NSPoint(x: 0, y: 40))

        #expect(rig.scrollView.contentView.bounds.origin == before)
    }

    @Test func theFocusedTextViewStillScrollsItsScrollView() {
        let rig = rig()
        #expect(rig.window.makeFirstResponder(rig.textView))
        let before = rig.scrollView.contentView.bounds.origin

        rig.textView.scroll(NSPoint(x: 0, y: 40))

        #expect(rig.scrollView.contentView.bounds.origin != before)
    }
}
#endif
