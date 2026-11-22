#if os(macOS)
import AppKit
import PalChat
import PalDesign
import PalDiagnostics
import SwiftUI

struct SelectableMarkdownText: View {
    let text: SelectableText
    let highlight: String
    let isCurrentMatch: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatInk) private var chatInk
    @Environment(\.hermesTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        SelectableTextRepresentable(spec: spec, openURL: openURL)
    }

    private var spec: SelectableTextSpec {
        let mark = FindMark(ink: chatInk, surfaceText: nil, isCurrent: isCurrentMatch)
        return SelectableTextSpec(
            text: text,
            style: SelectableTextStyle(
                highlight: highlight,
                isCurrentMatch: isCurrentMatch,
                isDark: colorScheme == .dark,
                ink: PalTokens.textPrimary,
                secondaryInk: Color(theme.palette.textSecondary),
                highlightFill: mark.fill,
                highlightInk: mark.text
            )
        )
    }
}

enum SelectableAttributedBuilder {
    static let indentStep: CGFloat = 25.7

    private struct Inks {
        let ink: NSColor
        let secondaryInk: NSColor
        let codeBackground: NSColor
        let fonts = FontMemo()
    }

    private struct FontKey: Hashable {
        let size: CGFloat
        let bold: Bool
        let italic: Bool
        let monospaced: Bool
    }

    private final class FontMemo {
        private var fonts: [FontKey: NSFont] = [:]

        func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> NSFont {
            let key = FontKey(size: size, bold: bold, italic: italic, monospaced: monospaced)
            if let font = fonts[key] { return font }
            let made = SelectableAttributedBuilder.font(size: size, bold: bold, italic: italic, monospaced: monospaced)
            fonts[key] = made
            return made
        }
    }

    struct Palette {
        let ink: NSColor
        let secondaryInk: NSColor
        let highlightFill: NSColor
        let highlightInk: NSColor?
        let isDark: Bool
    }

    static func build(_ text: SelectableText, highlight: String, isCurrent: Bool, palette: Palette) -> NSAttributedString {
        let inks = Inks(
            ink: palette.ink,
            secondaryInk: palette.secondaryInk,
            codeBackground: palette.ink.withAlphaComponent(palette.isDark ? 0.12 : 0.07)
        )
        let result = NSMutableAttributedString()
        var textRanges: [NSRange] = []
        let lastIndex = text.paragraphs.count - 1
        for (index, paragraph) in text.paragraphs.enumerated() {
            textRanges.append(append(paragraph, isLast: index == lastIndex, inks: inks, to: result))
        }
        applyHighlight(highlight, fill: palette.highlightFill, ink: isCurrent ? palette.highlightInk : nil, in: textRanges, of: result)
        return result
    }

    private static func append(_ paragraph: SelectableParagraph, isLast: Bool, inks: Inks, to result: NSMutableAttributedString) -> NSRange {
        let sizing = metrics(for: paragraph.style)
        let line = ChatLineBox(fontSize: sizing.size)
        let style = paragraphStyle(for: paragraph, line: line, isLast: isLast)
        let baseFont = inks.fonts.font(size: sizing.size, bold: sizing.bold, italic: false, monospaced: false)
        if !paragraph.marker.isEmpty {
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .font: inks.fonts.font(size: PalTextStyle.chatBody.size, bold: false, italic: false, monospaced: false),
                .foregroundColor: inks.secondaryInk,
                .paragraphStyle: style,
                .baselineOffset: line.baselineOffset,
            ]
            result.append(NSAttributedString(string: paragraph.marker + "\t", attributes: markerAttributes))
        }
        let start = result.length
        for run in paragraph.text.runs {
            let piece = String(paragraph.text[run.range].characters)
            var runAttributes = attributes(for: run, metrics: sizing, style: style, inks: inks)
            runAttributes[.baselineOffset] = line.baselineOffset
            result.append(NSAttributedString(string: piece, attributes: runAttributes))
        }
        let textRange = NSRange(location: start, length: result.length - start)
        if !isLast {
            let separator: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: inks.ink,
                .paragraphStyle: style,
                .baselineOffset: line.baselineOffset,
            ]
            result.append(NSAttributedString(string: "\n", attributes: separator))
        }
        return textRange
    }

    private static func metrics(for style: SelectableParagraph.Style) -> (size: CGFloat, bold: Bool) {
        switch style {
        case .body: (PalTextStyle.chatBody.size, false)
        case .heading(let level): ((level <= 2 ? PalTextStyle.chatStatus : PalTextStyle.chatBody).size, true)
        }
    }

    private static func attributes(
        for run: AttributedString.Runs.Run,
        metrics: (size: CGFloat, bold: Bool),
        style: NSParagraphStyle,
        inks: Inks
    ) -> [NSAttributedString.Key: Any] {
        let intent = run.inlinePresentationIntent ?? []
        let isCode = intent.contains(.code)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: inks.fonts.font(
                size: isCode ? PalTextStyle.chatCode.size : metrics.size,
                bold: metrics.bold || intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                monospaced: isCode
            ),
            .foregroundColor: inks.ink,
            .paragraphStyle: style,
        ]
        if isCode { attributes[.backgroundColor] = inks.codeBackground }
        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link {
            attributes[.link] = link
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    static func font(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let base = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func paragraphStyle(for paragraph: SelectableParagraph, line: ChatLineBox, isLast: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line.height
        style.maximumLineHeight = line.height
        style.paragraphSpacing = isLast ? 0 : ChatMetrics.blockSpacing
        guard paragraph.listDepth > 0 else { return style }
        let textIndent = CGFloat(paragraph.listDepth) * indentStep
        let markerIndent = CGFloat(paragraph.listDepth - 1) * indentStep
        style.firstLineHeadIndent = paragraph.marker.isEmpty ? textIndent : markerIndent
        style.headIndent = textIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: textIndent)]
        return style
    }

    private static func applyHighlight(_ query: String, fill: NSColor, ink: NSColor?, in textRanges: [NSRange], of result: NSMutableAttributedString) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let whole = NSString(string: result.string)
        for range in textRanges {
            var cursor = range.location
            let end = NSMaxRange(range)
            while cursor < end {
                let found = whole.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: cursor, length: end - cursor))
                guard found.location != NSNotFound, found.length > 0 else { break }
                result.addAttribute(.backgroundColor, value: fill, range: found)
                if let ink { result.addAttribute(.foregroundColor, value: ink, range: found) }
                cursor = NSMaxRange(found)
            }
        }
    }
}

private extension NSAppearance {
    func resolve<Value>(_ make: () -> Value) -> Value {
        var value: Value?
        performAsCurrentDrawingAppearance { value = make() }
        return value!
    }
}

private struct SelectableTextRepresentable: NSViewRepresentable {
    let spec: SelectableTextSpec
    let openURL: OpenURLAction

    func makeCoordinator() -> SelectableTextCoordinator { SelectableTextCoordinator() }

    func makeNSView(context: Context) -> PassiveTextView {
        let view = PassiveTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.textContainerInset = .zero
        view.focusRingType = .none
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.autoresizingMask = []
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.layoutManager?.allowsNonContiguousLayout = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PassiveTextView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.apply(spec, to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassiveTextView, context: Context) -> CGSize? {
        context.coordinator.size(forProposedWidth: proposal.width)
    }
}

@MainActor
private final class SelectableTextCoordinator: NSObject, NSTextViewDelegate {
    var openURL: OpenURLAction?

    private var appliedSpec: SelectableTextSpec?
    private var appliedAttributed: NSAttributedString?

    func apply(_ spec: SelectableTextSpec, to view: PassiveTextView) {
        guard spec != appliedSpec else { return }
        appliedSpec = spec
        let style = spec.style
        let appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua) ?? view.effectiveAppearance
        view.appearance = appearance
        let palette = appearance.resolve {
            SelectableAttributedBuilder.Palette(
                ink: NSColor(style.ink),
                secondaryInk: NSColor(style.secondaryInk),
                highlightFill: NSColor(style.highlightFill),
                highlightInk: style.highlightInk.map { NSColor($0) },
                isDark: style.isDark
            )
        }
        let attributed = SelectableTextCache.shared.attributed(for: spec) {
            PalPerf.interval("selectable.build") {
                appearance.resolve {
                    SelectableAttributedBuilder.build(spec.text, highlight: style.highlight, isCurrent: style.isCurrentMatch, palette: palette)
                }
            }
        }
        view.linkTextAttributes = [
            .foregroundColor: palette.ink,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        appliedAttributed = attributed
        replaceText(in: view, with: attributed)
        view.setAccessibilityValue(spec.text.plainText)
    }

    private func replaceText(in view: PassiveTextView, with attributed: NSAttributedString) {
        let previous = view.selectedRange()
        view.textStorage?.setAttributedString(attributed)
        if previous.length > 0, NSMaxRange(previous) <= attributed.length {
            view.setSelectedRange(previous)
        }
    }

    func size(forProposedWidth proposed: CGFloat?) -> CGSize {
        guard let text = appliedSpec?.text, let attributed = appliedAttributed else { return .zero }
        let width = SelectableTextLayout.clamp(proposed)
        let sizes = SelectableSizeCache.shared
        if sizes.noteRequested(width: width) { SelectableTextPrefetcher.shared.widthsChanged() }
        if let cached = sizes.size(for: text, width: width) { return cached }
        PalPerf.event("selectable.layout.main")
        return PalPerf.interval("selectable.layout") { sizes.fill(text, widths: [width]) { attributed } }[0]
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap({ URL(string: $0) }) else { return false }
        openURL?(url)
        return true
    }
}

final class PassiveTextView: NSTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    var selectedPlainText: String? {
        let whole = string as NSString
        let pieces = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map(whole.substring(with:))
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        guard let selectedPlainText else { return false }
        return pboard.setString(selectedPlainText, forType: .string)
    }

    static func selection(in window: NSWindow?, at point: NSPoint) -> String? {
        guard let view = window?.firstResponder as? PassiveTextView,
              view.convert(view.bounds, to: nil).contains(point)
        else { return nil }
        return view.selectedPlainText
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return super.hitTest(point) }
        let opensMessageMenu = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return opensMessageMenu ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func scroll(_ point: NSPoint) {
        guard window?.firstResponder === self else { return }
        super.scroll(point)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        matchContainerToFrame()
    }

    override func viewWillDraw() {
        matchContainerToFrame()
        super.viewWillDraw()
    }

    private func matchContainerToFrame() {
        let width = frame.width
        guard width > 0, let container = textContainer, container.size.width != width else { return }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
}
#endif
