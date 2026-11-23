import CoreGraphics

public enum InlineIconMetrics {
    public static func baselineOffset(iconHeight: CGFloat, capHeight: CGFloat, textShift: CGFloat) -> CGFloat {
        textShift + (capHeight - iconHeight) / 2
    }

    public static func baselineOffset(iconHeight: CGFloat, line: ChatLineBox) -> CGFloat {
        baselineOffset(iconHeight: iconHeight, capHeight: line.capHeight, textShift: line.textBaselineShift)
    }
}
