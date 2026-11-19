#if os(macOS)
import AppKit
import PalChat
import PalDesign
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
            highlight: highlight,
            isCurrentMatch: isCurrentMatch,
            isDark: colorScheme == .dark,
            ink: PalTokens.textPrimary,
            secondaryInk: Color(theme.palette.textSecondary),
            highlightFill: mark.fill,
            highlightInk: mark.text
        )
    }
}

enum SelectableAttributedBuilder {
    static let indentStep: CGFloat = 25.7
    static let lineSpacing: CGFloat = 3.2
    static let paragraphSpacing: CGFloat = 8

    private struct Inks {
        let ink: NSColor
        let secondaryInk: NSColor
        let codeBackground: NSColor
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
        let style = paragraphStyle(for: paragraph, isLast: isLast)
        let baseFont = font(size: sizing.size, bold: sizing.bold, italic: false, monospaced: false)
        if !paragraph.marker.isEmpty {
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .font: font(size: PalTextStyle.chatBody.size, bold: false, italic: false, monospaced: false),
                .foregroundColor: inks.secondaryInk,
                .paragraphStyle: style,
            ]
            result.append(NSAttributedString(string: paragraph.marker + "\t", attributes: markerAttributes))
        }
        let start = result.length
        for run in paragraph.text.runs {
            let piece = String(paragraph.text[run.range].characters)
            result.append(NSAttributedString(string: piece, attributes: attributes(for: run, metrics: sizing, style: style, inks: inks)))
        }
        let textRange = NSRange(location: start, length: result.length - start)
        if !isLast {
            result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: inks.ink, .paragraphStyle: style]))
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
            .font: font(
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

    private static func paragraphStyle(for paragraph: SelectableParagraph, isLast: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = isLast ? 0 : paragraphSpacing
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

private struct SelectableTextSpec: Equatable {
    let text: SelectableText
    let highlight: String
    let isCurrentMatch: Bool
    let isDark: Bool
    let ink: Color
    let secondaryInk: Color
    let highlightFill: Color
    let highlightInk: Color?
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

    private static let idealWidth: CGFloat = 10_000
    private static let cacheLimit = 8

    private let measureStorage = NSTextStorage()
    private let measureLayout = NSLayoutManager()
    private let measureContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private var appliedSpec: SelectableTextSpec?
    private var sizeCache: [CGFloat: CGSize] = [:]

    override init() {
        super.init()
        measureContainer.lineFragmentPadding = 0
        measureStorage.addLayoutManager(measureLayout)
        measureLayout.addTextContainer(measureContainer)
    }

    func apply(_ spec: SelectableTextSpec, to view: PassiveTextView) {
        guard spec != appliedSpec else { return }
        appliedSpec = spec
        let appearance = NSAppearance(named: spec.isDark ? .darkAqua : .aqua) ?? view.effectiveAppearance
        view.appearance = appearance
        var attributed = NSAttributedString()
        var linkInk = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            let inks = (NSColor(spec.ink), NSColor(spec.secondaryInk), NSColor(spec.highlightFill), spec.highlightInk.map { NSColor($0) })
            linkInk = inks.0
            attributed = SelectableAttributedBuilder.build(
                spec.text,
                highlight: spec.highlight,
                isCurrent: spec.isCurrentMatch,
                palette: .init(ink: inks.0, secondaryInk: inks.1, highlightFill: inks.2, highlightInk: inks.3, isDark: spec.isDark)
            )
        }
        view.linkTextAttributes = [
            .foregroundColor: linkInk,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        replaceText(in: view, with: attributed)
        view.setAccessibilityValue(spec.text.plainText)
    }

    private func replaceText(in view: PassiveTextView, with attributed: NSAttributedString) {
        let previous = view.selectedRange()
        view.textStorage?.setAttributedString(attributed)
        if previous.length > 0, NSMaxRange(previous) <= attributed.length {
            view.setSelectedRange(previous)
        }
        measureStorage.setAttributedString(attributed)
        sizeCache.removeAll()
    }

    func size(forProposedWidth proposed: CGFloat?) -> CGSize {
        let width = min(max(proposed ?? Self.idealWidth, 1), Self.idealWidth)
        if let cached = sizeCache[width] { return cached }
        measureContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        measureLayout.ensureLayout(for: measureContainer)
        let used = measureLayout.usedRect(for: measureContainer)
        let size = CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
        if sizeCache.count >= Self.cacheLimit { sizeCache.removeAll() }
        sizeCache[width] = size
        return size
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap({ URL(string: $0) }) else { return false }
        openURL?(url)
        return true
    }
}

private final class PassiveTextView: NSTextView {
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, let container = textContainer, container.size.width != newSize.width else { return }
        container.size = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
    }
}
#endif
