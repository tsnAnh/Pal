import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import HermesDesign

private let iconPackage = ProcessInfo.processInfo.environment["APP_ICON_OUTPUT"]

@Suite("App icon", .enabled(if: iconPackage != nil))
@MainActor
struct AppIconArtifact {
    private static let side = 1024
    private static let avatarScale: CGFloat = 1.367
    private static let avatarOffset = CGPoint(x: -0.03, y: 0.233)
    private static let eyeScale = 0.96
    private static let gaze = CGPoint(x: 0.04, y: -0.06)

    @Test func render() throws {
        let package = URL(fileURLWithPath: try #require(iconPackage), isDirectory: true)
        let art = try Self.image(artwork(canvas: CGFloat(Self.side)))
        try Self.write(art, to: package.appendingPathComponent("Assets/pal.png"))
    }

    private func artwork(canvas: CGFloat) -> some View {
        let spec = BotAvatarSpec(name: "Hermes", meta: BotAvatarMeta(shape: "blobatar:k7q2m9x0:round", color: "#ffffff", custom: true))
        var pose = AvatarMotion.staticPose(.idle)
        pose.eyeScale = Self.eyeScale
        pose.eyeX = Self.gaze.x
        pose.eyeY = Self.gaze.y
        return ZStack(alignment: .topLeading) {
            Color.black
            AvatarFrame(content: AvatarContent(spec), pose: pose, size: canvas * Self.avatarScale)
                .offset(x: canvas * Self.avatarOffset.x, y: canvas * Self.avatarOffset.y)
        }
        .frame(width: canvas, height: canvas)
        .clipped()
    }

    private static func image(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        return try redraw(rendered, side: side)
    }

    private static func redraw(_ image: CGImage, side: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return try #require(context.makeImage())
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
