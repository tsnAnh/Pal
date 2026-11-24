import CoreGraphics

public enum ChatImageFit {
    public static let placeholderRatio: CGFloat = 4.0 / 3.0

    public static func ratio(pixelWidth: Int?, pixelHeight: Int?) -> CGFloat {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return placeholderRatio }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    public static func size(ratio: CGFloat, in box: CGSize) -> CGSize {
        guard ratio > 0, box.width > 0, box.height > 0 else { return box }
        let width = min(box.width, box.height * ratio)
        return CGSize(width: width.rounded(), height: (width / ratio).rounded())
    }
}
