import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PalDesign

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
        ("blob", spec("chó pal bot", shape: "blobatar:k7q2m9x0:round", color: "#f4f4f4")),
        ("classic", spec("Atlas", shape: "squircle", color: "#3e8ef7")),
        ("sigil", spec("Rune", shape: "sigil-3", color: "#f5a524")),
    ]

    private struct Motion {
        var name: String
        var duration: Double
        var pose: (Double) -> AvatarPose
    }

    private static let sequenceSeconds = 30.0

    private static func clipPose(_ name: String, atFraction fraction: Double) -> AvatarPose {
        let clip = LoadingClips.all.first { $0.name == name }!
        return clip.pose(at: clip.duration * fraction)
    }

    private static func doneMotion(for spec: BotAvatarSpec) -> Motion {
        let delay = AvatarBlink.delaySeconds(for: spec.blinkKey)
        let seed = LoadingSequence.seed(for: spec.blinkKey)
        let working = AvatarMoodClock(mood: .work, since: start, blinkDelay: delay, loadingSeed: seed, reduceMotion: false)
        let clock = working.changing(to: .done, at: start)
        return Motion(name: "done", duration: AvatarMood.doneDuration + 0.6) { clock.pose(at: start.addingTimeInterval($0)) }
    }

    private static func loadingMotions(for spec: BotAvatarSpec) -> [Motion] {
        let delay = AvatarBlink.delaySeconds(for: spec.blinkKey)
        let seed = LoadingSequence.seed(for: spec.blinkKey)
        let idle = AvatarMoodClock(mood: .idle, since: start.addingTimeInterval(-10), blinkDelay: delay, loadingSeed: seed, reduceMotion: false)
        let clock = idle.changing(to: .work, at: start)
        let sequence = Motion(name: "sequence", duration: sequenceSeconds) { clock.pose(at: start.addingTimeInterval($0)) }
        let clips = (LoadingClips.all + SolidClips.all).map { clip in
            Motion(name: "clip-\(clip.name)", duration: clip.duration) { clip.pose(at: $0) }
        }
        return clips + [sequence]
    }

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("frames for every loading clip, the 30 s sequence and the done motion")
    func frames() throws {
        let root = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        for (index, (kind, spec)) in Self.featured.enumerated() {
            let content = AvatarContent(spec)
            let motions = (index == 0 ? Self.loadingMotions(for: spec) : []) + [Self.doneMotion(for: spec)]
            for motion in motions {
                let folder = root.appendingPathComponent("frames/\(kind)-\(motion.name)", isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let count = Int((motion.duration * framesPerSecond).rounded())
                for frame in 0..<count {
                    let pose = motion.pose(Double(frame) / framesPerSecond)
                    let view = ZStack { stage; AvatarFrame(content: content, pose: pose, size: 116) }
                        .frame(width: 160, height: 160)
                    try writePNG(view, scale: 2, to: folder.appendingPathComponent(String(format: "%04d.png", frame)))
                }
            }
        }
    }

    private static let realSizes: [CGFloat] = [25, 28, 43, 56, 66, 79, 88, 136, 160]
    private static let sheetShapes: [(String, BotAvatarSpec)] = [
        ("round", spec("Atlas", shape: "blobatar:k7q2m9x0:round", color: "#f4f4f4")),
        ("organic", spec("Atlas", shape: "blobatar:k7q2m9x0:organic", color: "#8b5cf6")),
        ("capsule", spec("Atlas", shape: "blobatar:k7q2m9x0:capsule", color: "#3e8ef7")),
        ("cloud", spec("Atlas", shape: "cloud", color: "#f5a524")),
        ("squircle", spec("Atlas", shape: "squircle", color: "#3e8ef7")),
        ("pill", spec("Atlas", shape: "pill", color: "#2ec27e")),
        ("hexagon", spec("Atlas", shape: "hexagon", color: "#e5484d")),
    ]

    @Test("rest, hover at the centre, hover right, hover up and hover left at the app's real sizes")
    func hoverStates() throws {
        let root = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let states: [(String, AvatarLook)] = [
            ("rest", .zero),
            ("hover centre", AvatarLook(amount: 1, x: 0, y: 0)),
            ("hover right", AvatarLook(amount: 1, x: 1, y: 0)),
            ("hover left", AvatarLook(amount: 1, x: -1, y: 0)),
            ("hover up", AvatarLook(amount: 1, x: 0, y: -1)),
            ("hover far right", AvatarLook(amount: 0.5, x: 1, y: 0.4)),
        ]
        for (kind, spec) in Self.sheetShapes {
            let content = AvatarContent(spec)
            let sheet = VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    HStack(spacing: 8) {
                        Text(state.0).font(.system(size: 11)).foregroundStyle(.white).frame(width: 96, alignment: .leading)
                        ForEach(Self.realSizes, id: \.self) { size in
                            AvatarFrame(content: content, pose: .rest, size: size, look: state.1)
                                .frame(width: size * 1.35, height: size * 1.35)
                        }
                    }
                }
            }
            .padding(12)
            .background(stage)
            try writePNG(sheet, scale: 2, to: root.appendingPathComponent("hover-\(kind).png"))
        }
    }

    @Test("a contact sheet for every 2D and 3D loading clip at 28, 44 and 116 points")
    func clipSheets() throws {
        let root = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        let folder = root.appendingPathComponent("clip-sheets", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = AvatarContent(Self.featured[0].1)
        let columns = 10
        let sizes: [CGFloat] = [28, 44, 116]
        for (index, clip) in (LoadingClips.all + SolidClips.all).enumerated() {
            let poses = (0..<columns).map { clip.pose(at: clip.duration * Double($0) / Double(columns - 1)) }
            let sheet = VStack(alignment: .leading, spacing: 4) {
                Text("\(index < LoadingClips.all.count ? "2D" : "3D") \(clip.name) \(String(format: "%.1f", clip.duration)) s")
                    .font(.system(size: 11)).foregroundStyle(.white)
                ForEach(sizes, id: \.self) { size in
                    HStack(spacing: 2) {
                        ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                            AvatarFrame(content: content, pose: pose, size: size).frame(width: size * 1.3, height: size * 1.3)
                        }
                    }
                }
            }
            .padding(8)
            .background(stage)
            try writePNG(sheet, scale: 2, to: folder.appendingPathComponent(String(format: "%02d-%@.png", index, clip.name)))
        }
    }

    @Test("every blob kind at rest, the way the shapes gallery shows them")
    func restKinds() throws {
        let root = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let kinds = BlobKind.allCases
        let sheet = VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(kinds.dropFirst(row * 5).prefix(5), id: \.self) { kind in
                        VStack(spacing: 6) {
                            AvatarFrame(content: AvatarContent(spec("pal", shape: "blobatar::\(kind.rawValue)", color: "#ffffff")), pose: .rest, size: 100)
                                .frame(width: 130, height: 120)
                            Text(kind.rawValue).font(.system(size: 13)).foregroundStyle(.gray)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.055))
        try writePNG(sheet, scale: 1, to: root.appendingPathComponent("rest-kinds.png"))
        let ladder = HStack(alignment: .bottom, spacing: 18) {
            ForEach([24, 32, 44, 72, 120] as [CGFloat], id: \.self) { size in
                AvatarFrame(content: AvatarContent(spec("pal", shape: "blobatar::round", color: "#ffffff")), pose: .rest, size: size)
                    .frame(width: size, height: size)
            }
        }
        .padding(14)
        .background(Color(white: 0.055))
        try writePNG(ladder, scale: 1, to: root.appendingPathComponent("rest-ladder.png"))
        let colors = ["#ffffff", "#f4f4f4", "#ffd60a", "#ff7a00", "#e5484d", "#ec4899", "#8b5cf6", "#3e8ef7", "#5ad1e0", "#30a46c", "#6b7280", "#14213d"]
        let themes = VStack(spacing: 0) {
            ForEach([(ColorScheme.dark, Color(white: 0.055)), (.light, Color(white: 0.97))], id: \.0) { scheme, page in
                HStack(spacing: 10) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                        BotAvatarView(spec: spec("bot\(index)", shape: "blobatar:k7q2m9x0:\(BlobKind.allCases[index % BlobKind.allCases.count].rawValue)", color: color), size: 56, animated: false)
                            .frame(width: 64, height: 64)
                    }
                }
                .padding(14)
                .background(page)
                .environment(\.colorScheme, scheme)
            }
        }
        try writePNG(themes, scale: 2, to: root.appendingPathComponent("eye-ink-themes.png"))
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

        let clipBeats = ["spin", "scan-down", "glance-blink", "drop", "squint", "double-take", "sleepy", "surprise", "bounce", "dot-stare"]
        let doneBeats: [Double] = [0.4, 0.8, 1.26, 2.0]
        let poses = clipBeats.map { Self.clipPose($0, atFraction: 0.5) }
            + doneBeats.map { AvatarMotion.pose(.done, at: $0, seed: 0) }

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
                    ForEach(Array([Self.clipPose("scan-down", atFraction: 0.3), Self.clipPose("surprise", atFraction: 0.5), AvatarMotion.pose(.done, at: 0.8, seed: 0)].enumerated()), id: \.offset) { _, pose in
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
