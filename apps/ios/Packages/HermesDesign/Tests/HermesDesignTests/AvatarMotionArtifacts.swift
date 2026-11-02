import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import HermesDesign

private let outputDirectory = ProcessInfo.processInfo.environment["AVATAR_MOTION_ARTIFACTS"]
private let framesPerSecond = 30.0
private let stage = Color(white: 0.11)

private func spec(_ name: String, shape: String, color: String) -> BotAvatarSpec {
    BotAvatarSpec(name: name, meta: BotAvatarMeta(shape: shape, color: color, custom: true))
}

@MainActor
private func writePNG(_ view: some View, scale: CGFloat, to url: URL) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    let image = try #require(renderer.cgImage)
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func photoData() throws -> Data {
    let side = 64
    let context = try #require(CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let gradient = try #require(CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [CGColor(srgbRed: 0.95, green: 0.55, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.3, green: 0.2, blue: 0.7, alpha: 1)] as CFArray,
        locations: [0, 1]
    ))
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite("Motion artifacts", .enabled(if: outputDirectory != nil), .serialized)
@MainActor
struct AvatarMotionArtifacts {
    private static let featured: [(String, BotAvatarSpec)] = [
        ("blob", spec("chó grok bot", shape: "blobatar:k7q2m9x0:round", color: "#f4f4f4")),
        ("classic", spec("Atlas", shape: "squircle", color: "#3e8ef7")),
        ("sigil", spec("Rune", shape: "sigil-3", color: "#f5a524")),
    ]

    private struct Motion {
        var name: String
        var clock: AvatarMoodClock
        var duration: Double
    }

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func motions(for spec: BotAvatarSpec) -> [Motion] {
        let delay = AvatarBlink.delaySeconds(for: spec.blinkKey)
        let idle = AvatarMoodClock(mood: .idle, since: start.addingTimeInterval(-10), blinkDelay: delay, reduceMotion: false)
        let working = AvatarMoodClock(mood: .work, since: start, blinkDelay: delay, reduceMotion: false)
        return [
            Motion(name: "loading", clock: idle.changing(to: .work, at: start), duration: AvatarMotion.loopDuration),
            Motion(name: "done", clock: working.changing(to: .done, at: start), duration: AvatarMood.doneDuration + 0.6),
        ]
    }

    @Test("frames for every featured avatar and motion")
    func frames() throws {
        let root = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        for (kind, spec) in Self.featured {
            let content = AvatarContent(spec)
            for motion in Self.motions(for: spec) {
                let folder = root.appendingPathComponent("frames/\(kind)-\(motion.name)", isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let count = Int((motion.duration * framesPerSecond).rounded())
                for index in 0..<count {
                    let pose = motion.clock.pose(at: Self.start.addingTimeInterval(Double(index) / framesPerSecond))
                    let view = ZStack { stage; AvatarFrame(content: content, pose: pose, size: 116) }
                        .frame(width: 160, height: 160)
                    try writePNG(view, scale: 2, to: folder.appendingPathComponent(String(format: "%04d.png", index)))
                }
            }
        }
    }

    @Test("every avatar kind at every size through the key poses")
    func gallery() throws {
        let root = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rows: [(String, BotAvatarSpec)] = BlobKind.allCases.map {
            ("blob \($0.rawValue)", spec("kind-\($0.rawValue)", shape: "blobatar:k7q2m9x0:\($0.rawValue)", color: "#f4f4f4"))
        }
        rows += ClassicShape.allCases.map { ("classic \($0.rawValue)", spec("Atlas", shape: $0.rawValue, color: "#3e8ef7")) }
        rows += [("sigil", spec("Rune", shape: "sigil-3", color: "#f5a524"))]
        rows += [("photo", BotAvatarSpec(name: "Pic", meta: BotAvatarMeta(imageKind: .photo), photo: try photoData()))]

        let loopBeats: [Double] = [0, 0.66, 1.2, 2.35, 5.9, 6.03, 8.2, 8.62, 8.8, 9.5]
        let doneBeats: [Double] = [0.4, 0.8, 1.26, 2.0]
        let poses = loopBeats.map { AvatarMotion.pose(.work, at: $0) } + doneBeats.map { AvatarMotion.pose(.done, at: $0) }

        let grid = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.0).font(.system(size: 11)).foregroundStyle(.white).frame(width: 110, alignment: .leading)
                    ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                        AvatarFrame(content: AvatarContent(row.1), pose: pose, size: 44).frame(width: 60, height: 60)
                    }
                }
            }
        }
        .padding(12)
        .background(stage)
        try writePNG(grid, scale: 2, to: root.appendingPathComponent("gallery-kinds.png"))

        let sizes: [CGFloat] = [28, 56, 136]
        let sizeSheet = VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.featured.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(Array([AvatarMotion.pose(.work, at: 1.2), AvatarMotion.pose(.work, at: 8.62), AvatarMotion.pose(.done, at: 0.8)].enumerated()), id: \.offset) { _, pose in
                        ForEach(sizes, id: \.self) { size in
                            AvatarFrame(content: AvatarContent(row.1), pose: pose, size: size).frame(width: size * 1.4, height: size * 1.4)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(stage)
        try writePNG(sizeSheet, scale: 3, to: root.appendingPathComponent("gallery-sizes.png"))
    }
}
