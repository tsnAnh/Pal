import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PalDesign

@MainActor
enum SolidPixelGate {
    static let referenceDirectoryKey = "PAL_AVATAR_REFERENCE_DIR"
    static let recordKey = "PAL_AVATAR_RECORD"
    static let sizes: [CGFloat] = [20, 26, 51, 66, 79, 201]
    static let scale: CGFloat = 2

    struct Look {
        let name: String
        let solid: AvatarSolid
        let outline: AvatarOutline?
    }

    struct Frame {
        let name: String
        let pose: AvatarPose
        let look: AvatarLook
    }

    static let looks: [Look] = [
        Look(name: "round-blue", solid: solid("blobatar:k7q2m9x0:round"), outline: nil),
        Look(name: "organic-coral", solid: solid("blobatar:k7q2m9x0:organic", color: "#f26d5b"), outline: nil),
        Look(
            name: "boxy-outline", solid: solid("blobatar:k7q2m9x0:boxy", color: "#8e5cf0"),
            outline: AvatarOutline(gap: 2, thickness: 3, color: .orange)
        ),
        Look(name: "burst-teal", solid: solid("blobatar:k7q2m9x0:burst", color: "#27a6a0"), outline: nil),
        Look(name: "classic-pill", solid: solid("pill", color: "#f5b942"), outline: nil),
        Look(name: "cloud-white-light", solid: solid("blobatar:k7q2m9x0:cloud", color: "#ffffff").toned(for: .light), outline: nil),
        Look(name: "gem-dark", solid: solid("blobatar:k7q2m9x0:gem", color: "#1c1c1e"), outline: nil),
    ]

    static let frames: [Frame] = [
        Frame(name: "rest", pose: .rest, look: .zero),
        Frame(name: "mid-turn", pose: AvatarPose.facing.with { $0.eyeX = 0.4; $0.eyeY = -0.2; $0.yaw = 18; $0.pitch = -9 }, look: .zero),
        Frame(name: "blink", pose: AvatarPose.facing.with { $0.eyeOpen = 0.12 }, look: .zero),
        Frame(
            name: "bob-high",
            pose: AvatarPose.facing.with { $0.bodyY = -0.06; $0.bodyScaleX = 0.95; $0.bodyScaleY = 1.06; $0.bodyRotation = 4 },
            look: .zero
        ),
        Frame(
            name: "bob-low",
            pose: AvatarPose.facing.with { $0.bodyY = 0.05; $0.bodyScaleX = 1.07; $0.bodyScaleY = 0.93; $0.bodyRotation = -4 },
            look: .zero
        ),
        Frame(
            name: "happy",
            pose: AvatarPose.facing.with { $0.eyeHappy = 1; $0.eyeScale = 1.1; $0.eyeRoll = 8; $0.pairSpin = 5 },
            look: .zero
        ),
        Frame(name: "look-spring-mid", pose: .facing, look: AvatarLook(amount: 0.55, x: 0.35, y: -0.4)),
        Frame(name: "faded", pose: AvatarPose.rest.with { $0.opacity = 0.6 }, look: .zero),
    ]

    static func render(_ look: Look, _ frame: Frame, size: CGFloat) -> CGImage? {
        let side = size * 1.6
        let content = SolidCanvas(
            solid: look.solid, pose: frame.pose, size: size, look: frame.look, outline: look.outline, reduceMotion: false
        )
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    static func fileName(_ look: Look, _ frame: Frame, size: CGFloat) -> String {
        "\(look.name)_\(Int(size))_\(frame.name).png"
    }

    static func pixels(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    struct Difference: Equatable {
        var pixels = 0
        var worstChannel = 0
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Difference {
        var result = Difference()
        for pixel in 0..<(a.count / 4) {
            var worst = 0
            for channel in 0..<4 { worst = max(worst, abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel]))) }
            if worst > 0 { result.pixels += 1 }
            result.worstChannel = max(result.worstChannel, worst)
        }
        return result
    }
}

@Suite("Solid avatar pixels", .serialized)
@MainActor
struct SolidPixelGateTests {
    private var referenceDirectory: URL? {
        ProcessInfo.processInfo.environment[SolidPixelGate.referenceDirectoryKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var recording: Bool { ProcessInfo.processInfo.environment[SolidPixelGate.recordKey] == "1" }

    @Test("drawing the same frame twice gives the same pixels")
    func repeatable() throws {
        for look in SolidPixelGate.looks {
            for frame in SolidPixelGate.frames {
                for size in [SolidPixelGate.sizes[1], SolidPixelGate.sizes[5]] {
                    let first = try #require(SolidPixelGate.render(look, frame, size: size))
                    let second = try #require(SolidPixelGate.render(look, frame, size: size))
                    let a = try #require(SolidPixelGate.pixels(of: first))
                    let b = try #require(SolidPixelGate.pixels(of: second))
                    #expect(
                        SolidPixelGate.difference(a, b) == .init(),
                        "\(SolidPixelGate.fileName(look, frame, size: size)) changed between two draws"
                    )
                }
            }
        }
    }

    @Test("every look, size and pose renders the pixels recorded from the reference renderer exactly")
    func matchesReference() throws {
        guard let directory = referenceDirectory else { return }
        if recording { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var checked = 0
        for look in SolidPixelGate.looks {
            for frame in SolidPixelGate.frames {
                for size in SolidPixelGate.sizes {
                    let name = SolidPixelGate.fileName(look, frame, size: size)
                    let image = try #require(SolidPixelGate.render(look, frame, size: size), "\(name) did not render")
                    let url = directory.appendingPathComponent(name)
                    if recording {
                        try #require(SolidPixelGate.png(image)).write(to: url)
                        continue
                    }
                    let reference = try #require(SolidPixelGate.decode(url), "\(name) has no reference")
                    #expect(reference.width == image.width && reference.height == image.height, "\(name) changed size")
                    guard reference.width == image.width, reference.height == image.height else { continue }
                    let expected = try #require(SolidPixelGate.pixels(of: reference))
                    let actual = try #require(SolidPixelGate.pixels(of: image))
                    let diff = SolidPixelGate.difference(expected, actual)
                    #expect(diff == .init(), "\(name): \(diff.pixels) pixels differ, worst channel \(diff.worstChannel)")
                    checked += 1
                }
            }
        }
        if !recording {
            #expect(checked == SolidPixelGate.looks.count * SolidPixelGate.frames.count * SolidPixelGate.sizes.count)
        }
    }
}
