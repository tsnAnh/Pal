import CoreGraphics

public enum MediaPosterAspect {
    public static let narrowest: CGFloat = 0.75
    public static let widest: CGFloat = 2

    public static func ratio(width: Int?, height: Int?) -> CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return min(max(CGFloat(width) / CGFloat(height), narrowest), widest)
    }

    public static func height(
        forWidth tileWidth: CGFloat, mediaWidth: Int?, mediaHeight: Int?, placeholder: CGFloat = MediaTileMetrics.singleHeight
    ) -> CGFloat {
        guard let ratio = ratio(width: mediaWidth, height: mediaHeight) else { return placeholder }
        return (tileWidth / ratio).rounded()
    }
}
