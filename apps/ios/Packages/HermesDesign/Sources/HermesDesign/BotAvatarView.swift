import CoreGraphics
import ImageIO
import SwiftUI

public struct BotAvatarView: View {
    private let spec: BotAvatarSpec
    private let size: CGFloat
    private let mood: AvatarMood
    private let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var clock: AvatarMoodClock

    public init(spec: BotAvatarSpec, size: CGFloat, mood: AvatarMood = .idle, animated: Bool = true) {
        self.spec = spec
        self.size = size
        self.mood = mood
        self.animated = animated
        _clock = State(initialValue: AvatarMoodClock(
            mood: mood,
            since: Date(),
            blinkDelay: AvatarBlink.delaySeconds(for: spec.blinkKey),
            loadingSeed: LoadingSequence.seed(for: spec.blinkKey),
            reduceMotion: false
        ))
    }

    public var body: some View {
        let content = AvatarContent(spec).toned(for: colorScheme)
        Group {
            if animated {
                let clock = resolvedClock
                TimelineView(AvatarSchedule(clock: clock, frameInterval: reduceMotion ? 1.0 / 20 : 1.0 / 60)) { context in
                    AvatarFrame(content: content, pose: clock.pose(at: context.date), size: size)
                }
            } else {
                AvatarFrame(content: content, pose: AvatarMotion.staticPose(mood), size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: mood) { _, next in
            clock = resolvedClock.changing(to: next, at: Date())
        }
    }

    private var resolvedClock: AvatarMoodClock {
        var resolved = clock
        resolved.blinkDelay = AvatarBlink.delaySeconds(for: spec.blinkKey)
        resolved.loadingSeed = LoadingSequence.seed(for: spec.blinkKey)
        resolved.reduceMotion = reduceMotion
        return resolved
    }
}

extension BotAvatarSpec {
    var blinkKey: String {
        switch self {
        case .photo(let photo): photo.fallback.blinkKey
        case .shape(let shape): shape.blinkKey
        }
    }
}

extension ShapeAvatar {
    var blinkKey: String {
        switch self {
        case .blob(let blob): blob.seed
        case .sigil(let sigil): sigil.name
        case .classic(let classic): classic.shape.rawValue + classic.color.css
        }
    }
}

enum AvatarContent {
    case rig(AvatarRig)
    case photo(CGImage)

    init(_ spec: BotAvatarSpec) {
        switch spec {
        case .photo(let photo):
            if let image = Self.decode(photo.data) {
                self = .photo(image)
            } else {
                self = .rig(Self.rig(photo.fallback))
            }
        case .shape(let shape):
            self = .rig(Self.rig(shape))
        }
    }

    static func rig(_ shape: ShapeAvatar) -> AvatarRig {
        switch shape {
        case .blob(let blob): BlobFaceDrawing.make(blob)
        case .sigil(let sigil): SigilDrawing.make(sigil)
        case .classic(let classic): ClassicDrawing.make(classic)
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

struct AvatarFrame: View {
    let content: AvatarContent
    let pose: AvatarPose
    let size: CGFloat

    var body: some View {
        switch content {
        case .rig(let rig):
            AvatarCanvas(rig: rig, pose: pose, size: size)
        case .photo(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .scaleEffect(x: pose.bodyScaleX, y: pose.bodyScaleY)
                .rotationEffect(.degrees(pose.bodyRotation))
                .offset(x: pose.bodyX * size, y: pose.bodyY * size)
                .opacity(pose.opacity)
        }
    }
}

private struct AvatarCanvas: View {
    let rig: AvatarRig
    let pose: AvatarPose
    let size: CGFloat

    var body: some View {
        let inset = (size * 0.3).rounded()
        let side = size + 2 * inset
        Canvas { context, _ in
            AvatarPainter(rig: rig, size: size, inset: inset).paint(pose, in: &context)
        }
        .frame(width: side, height: side)
        .frame(width: size, height: size)
    }
}

private struct AvatarPainter {
    let rig: AvatarRig
    let size: CGFloat
    let inset: CGFloat

    private var scale: CGFloat { size / max(rig.viewBox.width, rig.viewBox.height) }

    private var placement: CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (size - rig.viewBox.width * scale) / 2 + inset,
            y: (size - rig.viewBox.height * scale) / 2 + inset
        ))
    }

    func paint(_ pose: AvatarPose, in context: inout GraphicsContext) {
        let pivot = rig.pivot.applying(placement)
        context.translateBy(x: pivot.x + pose.bodyX * rig.span * scale, y: pivot.y + pose.bodyY * rig.span * scale)
        context.rotate(by: .degrees(pose.bodyRotation))
        context.scaleBy(x: pose.bodyScaleX, y: pose.bodyScaleY)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        if pose.opacity < 1 {
            context.opacity = pose.opacity
            context.drawLayer { layer in paintFigure(pose, in: &layer) }
        } else {
            paintFigure(pose, in: &context)
        }
    }

    private func paintFigure(_ pose: AvatarPose, in context: inout GraphicsContext) {
        let place = placement
        if rig.clipsToViewBox {
            context.clip(to: Path(CGRect(x: inset, y: inset, width: size, height: size)))
        }
        for element in rig.body {
            draw(element, in: &context)
        }
        let eyes = rig.eyePaths(pose).map { $0.applying(place) }
        let eyeColor = rig.eyes.fill.swiftUIColor
        context.drawLayer { layer in
            layer.clipToLayer { mask in
                for element in rig.eyes.mask { draw(element, in: &mask, silhouette: true) }
            }
            for eye in eyes { layer.fill(eye, with: .color(eyeColor)) }
        }
        for (index, dot) in rig.dots.enumerated() where index < 3 && pose.dots[index] > 0 {
            var shown = dot
            shown.opacity = pose.dots[index]
            draw(shown, in: &context)
        }
    }

    private func draw(_ element: AvatarDrawing.Element, in context: inout GraphicsContext, silhouette: Bool = false) {
        let path = element.path.applying(placement)
        let paint = { (target: inout GraphicsContext) in
            if let fill = element.fill {
                target.fill(path, with: .color(silhouette ? .black : fill.swiftUIColor))
            }
            if let stroke = element.stroke {
                target.stroke(
                    path,
                    with: .color(silhouette ? .black : stroke.color.swiftUIColor),
                    style: StrokeStyle(
                        lineWidth: stroke.width * scale,
                        lineCap: stroke.round ? .round : .butt,
                        lineJoin: stroke.round ? .round : .miter
                    )
                )
            }
        }
        guard element.opacity < 1, !silhouette else {
            paint(&context)
            return
        }
        var faded = context
        faded.opacity = context.opacity * element.opacity
        if element.fill != nil, element.stroke != nil {
            faded.drawLayer { layer in paint(&layer) }
        } else {
            paint(&faded)
        }
    }
}
