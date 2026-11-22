#if os(macOS)
import AppKit
import PalChat

enum SelectableTextLayout {
    static let minimumWidth: CGFloat = 1
    static let idealWidth: CGFloat = 10_000

    static func clamp(_ proposed: CGFloat?) -> CGFloat {
        min(max(proposed ?? idealWidth, minimumWidth), idealWidth)
    }

    static func attributed(for text: SelectableText) -> NSAttributedString {
        SelectableAttributedBuilder.build(
            text,
            highlight: "",
            isCurrent: false,
            palette: SelectableAttributedBuilder.Palette(
                ink: .black,
                secondaryInk: .black,
                highlightFill: .clear,
                highlightInk: nil,
                isDark: false
            )
        )
    }

    static func fitted(_ used: CGRect, in width: CGFloat) -> CGSize {
        CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }

    final class Session {
        private let storage: NSTextStorage
        private let manager = NSLayoutManager()
        private let container: NSTextContainer

        init(_ attributed: NSAttributedString) {
            storage = NSTextStorage(attributedString: attributed)
            container = NSTextContainer(size: NSSize(width: idealWidth, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        func size(width: CGFloat) -> CGSize {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            return fitted(manager.usedRect(for: container), in: width)
        }
    }
}
#endif
