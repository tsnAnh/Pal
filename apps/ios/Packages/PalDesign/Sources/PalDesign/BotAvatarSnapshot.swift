import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

public enum BotAvatarSnapshot {
    public static let pixels = 256
    static let fill: CGFloat = 0.8

    @MainActor
    public static func pngData(for spec: BotAvatarSpec, pixels: Int = pixels, scheme: ColorScheme = .light) -> Data? {
        let side = CGFloat(pixels)
        let content = BotAvatarView(spec: spec, size: side * fill, animated: false)
            .frame(width: side, height: side)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
