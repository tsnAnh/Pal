#if os(macOS)
import AppKit
import os
import PalChat
import SwiftUI

struct SelectableTextStyle: Hashable {
    let highlight: String
    let isCurrentMatch: Bool
    let isDark: Bool
    let ink: Color
    let secondaryInk: Color
    let highlightFill: Color
    let highlightInk: Color?
}

struct SelectableTextSpec: Equatable {
    let text: SelectableText
    let style: SelectableTextStyle

    static func == (lhs: SelectableTextSpec, rhs: SelectableTextSpec) -> Bool {
        lhs.style == rhs.style && (lhs.text.identity == rhs.text.identity || lhs.text == rhs.text)
    }
}

struct SelectableTextIdentity: Hashable {
    let address: Int
    let count: Int
}

extension SelectableText {
    var identity: SelectableTextIdentity {
        paragraphs.withUnsafeBufferPointer {
            SelectableTextIdentity(address: $0.baseAddress.map { Int(bitPattern: $0) } ?? 0, count: $0.count)
        }
    }
}

final class CacheKey<Key: Hashable>: NSObject {
    let key: Key

    init(_ key: Key) { self.key = key }

    override var hash: Int { key.hashValue }

    override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey<Key>)?.key == key }
}

@MainActor
final class SelectableTextCache {
    static let shared = SelectableTextCache()

    private struct BuiltKey: Hashable {
        let text: SelectableTextIdentity
        let style: SelectableTextStyle
    }

    private final class Built {
        let text: SelectableText
        let attributed: NSAttributedString

        init(text: SelectableText, attributed: NSAttributedString) {
            self.text = text
            self.attributed = attributed
        }
    }

    private let built: NSCache<CacheKey<BuiltKey>, Built> = {
        let cache = NSCache<CacheKey<BuiltKey>, Built>()
        cache.countLimit = 256
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    func attributed(for spec: SelectableTextSpec, make: () -> NSAttributedString) -> NSAttributedString {
        let key = CacheKey(BuiltKey(text: spec.text.identity, style: spec.style))
        if let hit = built.object(forKey: key) { return hit.attributed }
        let attributed = make()
        built.setObject(Built(text: spec.text, attributed: attributed), forKey: key, cost: attributed.length)
        return attributed
    }
}

final class SelectableSizeCache: @unchecked Sendable {
    static let shared = SelectableSizeCache()

    private static let recentWidthCapacity = 4

    private struct SizeKey: Hashable {
        let text: SelectableTextIdentity
        let width: CGFloat
    }

    private final class Measured {
        let text: SelectableText
        let size: CGSize

        init(text: SelectableText, size: CGSize) {
            self.text = text
            self.size = size
        }
    }

    private let measured: NSCache<CacheKey<SizeKey>, Measured> = {
        let cache = NSCache<CacheKey<SizeKey>, Measured>()
        cache.countLimit = 4096
        return cache
    }()

    private let widths = OSAllocatedUnfairLock(initialState: [CGFloat]())

    var recentWidths: [CGFloat] { widths.withLock { $0 } }

    func size(for text: SelectableText, width: CGFloat) -> CGSize? {
        measured.object(forKey: CacheKey(SizeKey(text: text.identity, width: width)))?.size
    }

    func store(_ size: CGSize, for text: SelectableText, width: CGFloat) {
        measured.setObject(Measured(text: text, size: size), forKey: CacheKey(SizeKey(text: text.identity, width: width)))
    }

    @discardableResult
    func fill(_ text: SelectableText, widths: [CGFloat], attributed: () -> NSAttributedString) -> [CGSize] {
        var session: SelectableTextLayout.Session?
        func layout(_ width: CGFloat) -> CGSize {
            let live = session ?? SelectableTextLayout.Session(attributed())
            session = live
            return live.size(width: width)
        }
        var natural: CGSize?
        func ideal() -> CGSize {
            if let natural { return natural }
            let known = size(for: text, width: SelectableTextLayout.idealWidth) ?? layout(SelectableTextLayout.idealWidth)
            natural = known
            store(known, for: text, width: SelectableTextLayout.idealWidth)
            return known
        }
        return widths.map { width in
            if let cached = size(for: text, width: width) { return cached }
            let resolved: CGSize
            if width <= SelectableTextLayout.minimumWidth {
                resolved = CGSize(width: min(width, ideal().width), height: ideal().height)
            } else if width >= ideal().width {
                resolved = ideal()
            } else {
                resolved = layout(width)
            }
            store(resolved, for: text, width: width)
            return resolved
        }
    }

    func noteRequested(width: CGFloat) -> Bool {
        guard width > SelectableTextLayout.minimumWidth, width < SelectableTextLayout.idealWidth else { return false }
        return widths.withLock { recent in
            if recent.first == width { return false }
            let isNew = !recent.contains(width)
            recent.removeAll { $0 == width }
            recent.insert(width, at: 0)
            if recent.count > Self.recentWidthCapacity { recent.removeLast() }
            return isNew
        }
    }
}
#endif
