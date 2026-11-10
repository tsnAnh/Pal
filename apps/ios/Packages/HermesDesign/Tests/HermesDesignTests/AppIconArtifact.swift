import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import HermesDesign

private let iconOutput = ProcessInfo.processInfo.environment["APP_ICON_OUTPUT"]

@Suite("App icon", .enabled(if: iconOutput != nil))
@MainActor
struct AppIconArtifact {
    private static let side = 1024
    private static let avatarScale: CGFloat = 1.367
    private static let avatarOffset = CGPoint(x: -0.03, y: 0.233)
    private static let eyeScale = 0.96
    private static let gaze = CGPoint(x: 0.04, y: -0.06)

    @Test func render() throws {
        let spec = BotAvatarSpec(name: "Hermes", meta: BotAvatarMeta(shape: "blobatar:k7q2m9x0:round", color: "#ffffff", custom: true))
        let canvas = CGFloat(Self.side)
        let avatar = canvas * Self.avatarScale
        var pose = AvatarMotion.staticPose(.idle)
        pose.eyeScale = Self.eyeScale
        pose.eyeX = Self.gaze.x
        pose.eyeY = Self.gaze.y
        let view = ZStack(alignment: .topLeading) {
            Color.black
            AvatarFrame(content: AvatarContent(spec), pose: pose, size: avatar)
                .offset(x: canvas * Self.avatarOffset.x, y: canvas * Self.avatarOffset.y)
        }
        .frame(width: canvas, height: canvas)
        .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        let context = try #require(CGContext(
            data: nil, width: Self.side, height: Self.side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        let opaque = try #require(context.makeImage())
        let url = URL(fileURLWithPath: try #require(iconOutput))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, opaque, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
