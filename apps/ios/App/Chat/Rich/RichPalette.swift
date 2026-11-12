import Foundation
import PalChat
import PalDesign
import SwiftUI

struct RichPalette {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        isDark = scheme == .dark
    }

    private func pick(dark: UInt32, light: UInt32) -> Color {
        Self.rgb(isDark ? dark : light)
    }

    static func rgb(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    func token(_ kind: CodeTokenKind) -> Color? {
        switch kind {
        case .plain: nil
        case .keyword: pick(dark: 0xFF7AB2, light: 0xAD3DA4)
        case .string: pick(dark: 0xFC6A5D, light: 0xC41A16)
        case .comment: pick(dark: 0x7F8C98, light: 0x5D6C79)
        case .number: pick(dark: 0xD0BF69, light: 0x1C00CF)
        case .type: pick(dark: 0x5DD8FF, light: 0x0B4F79)
        case .function: pick(dark: 0x67B7A4, light: 0x326D74)
        case .attribute: pick(dark: 0xFD8F3F, light: 0x947100)
        case .punctuation: PalTokens.textSecondary
        }
    }

    private static let darkStandard: [UInt32] = [0x555B66, 0xFF6B68, 0x5FD35F, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xD0D4DA]
    private static let darkBright: [UInt32] = [0x7F848E, 0xFF8F8C, 0x8CE68C, 0xF3D58D, 0x8CC8FF, 0xDB9CF0, 0x7FD1DB, 0xFFFFFF]
    private static let lightStandard: [UInt32] = [0x2B2F36, 0xC4281C, 0x1F8A2E, 0x8A6A00, 0x1D5FD0, 0x9B30B8, 0x127C8C, 0x6B7280]
    private static let lightBright: [UInt32] = [0x4B5563, 0xE0453A, 0x2FA842, 0xA67F00, 0x3B7BE8, 0xB44FD1, 0x1E98AB, 0x111827]
    private static let cubeLevels: [Int] = [0, 95, 135, 175, 215, 255]

    private func base(_ index: Int, bright: Bool) -> Color {
        let table = isDark ? (bright ? Self.darkBright : Self.darkStandard) : (bright ? Self.lightBright : Self.lightStandard)
        return Self.rgb(table[min(max(index, 0), 7)])
    }

    func ansi(_ color: ANSIColor) -> Color {
        switch color {
        case .standard(let index): base(index, bright: false)
        case .bright(let index): base(index, bright: true)
        case .indexed(let index): indexed(index)
        case .rgb(let r, let g, let b):
            Color(red: Double(min(max(r, 0), 255)) / 255, green: Double(min(max(g, 0), 255)) / 255, blue: Double(min(max(b, 0), 255)) / 255)
        }
    }

    private func indexed(_ value: Int) -> Color {
        let index = min(max(value, 0), 255)
        switch index {
        case 0..<8: return base(index, bright: false)
        case 8..<16: return base(index - 8, bright: true)
        case 16..<232:
            let offset = index - 16
            let levels = Self.cubeLevels
            return Color(
                red: Double(levels[offset / 36]) / 255,
                green: Double(levels[(offset / 6) % 6]) / 255,
                blue: Double(levels[offset % 6]) / 255
            )
        default:
            let gray = Double(8 + 10 * (index - 232)) / 255
            return Color(red: gray, green: gray, blue: gray)
        }
    }

    private var appPalette: PalPalette { isDark ? .measuredDark : .derivedLight }

    var addedTint: Color { Color(appPalette.workingDot).opacity(isDark ? 0.24 : 0.20) }
    var removedTint: Color { Color(appPalette.destructive).opacity(isDark ? 0.22 : 0.14) }
    var hunkTint: Color { Color(appPalette.accentBlue).opacity(isDark ? 0.18 : 0.08) }
}

enum RichCode {
    static var font: Font {
        #if os(macOS)
        .system(size: 12, design: .monospaced)
        #else
        .system(.footnote, design: .monospaced)
        #endif
    }

    static let collapseLines = 12

    static func lineCount(_ source: String) -> Int {
        source.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}

struct DiffModel: Sendable {
    let lines: [DiffLine]
    let added: Int
    let removed: Int
}

enum RichRendering {
    private final class Box<Value: Sendable>: NSObject {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, AnyObject> = {
        let cache = NSCache<NSString, AnyObject>()
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    private static func cached<Value: Sendable>(_ tag: String, _ source: String, _ make: () -> Value) -> Value {
        let key = "\(tag)|\(source.utf8.count)|\(source.hashValue)" as NSString
        if let hit = cache.object(forKey: key) as? Box<Value> { return hit.value }
        let value = make()
        cache.setObject(Box(value), forKey: key, cost: source.utf8.count)
        return value
    }

    static func kind(of block: MarkdownBlock) -> RichKind {
        let source = String(block.text.characters)
        let tag: String
        switch block.kind {
        case .code(let language): tag = "kind|\(language ?? "")"
        case .math: tag = "kind|math"
        default: tag = "kind|plain"
        }
        return cached(tag, source) { block.richKind }
    }

    static func code(_ source: String, language: String?, scheme: ColorScheme) -> AttributedString {
        cached("code|\(language ?? "")|\(scheme == .dark)", source) {
            guard let spans = CodeHighlighter.spans(language: language, code: source) else { return AttributedString(source) }
            let palette = RichPalette(scheme)
            var output = AttributedString()
            for span in spans {
                var piece = AttributedString(span.text)
                if let color = palette.token(span.kind) { piece.foregroundColor = color }
                output.append(piece)
            }
            return output
        }
    }

    static func diff(_ source: String) -> DiffModel {
        cached("diff", source) {
            let lines = DiffParser.parse(source)
            let stats = DiffParser.stats(lines)
            return DiffModel(lines: lines, added: stats.added, removed: stats.removed)
        }
    }

    static func terminal(_ source: String, scheme: ColorScheme) -> AttributedString {
        cached("terminal|\(scheme == .dark)", source) {
            let palette = RichPalette(scheme)
            var output = AttributedString()
            for segment in ANSIParser.parse(source) {
                var piece = AttributedString(segment.text)
                if let foreground = segment.foreground {
                    let color = palette.ansi(foreground)
                    piece.foregroundColor = segment.dim ? color.opacity(0.6) : color
                } else if segment.dim {
                    piece.foregroundColor = PalTokens.textSecondary
                }
                if let background = segment.background { piece.backgroundColor = palette.ansi(background) }
                var intent: InlinePresentationIntent = []
                if segment.bold { intent.insert(.stronglyEmphasized) }
                if segment.italic { intent.insert(.emphasized) }
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                if segment.underline { piece.underlineStyle = .single }
                output.append(piece)
            }
            return output
        }
    }

    static func plainTerminal(_ source: String) -> String {
        cached("terminal-plain", source) { ANSIParser.stripped(source) }
    }

    static func json(_ source: String) -> JSONPresentation? {
        cached("json", source) { JSONPretty.present(source) }
    }
}
