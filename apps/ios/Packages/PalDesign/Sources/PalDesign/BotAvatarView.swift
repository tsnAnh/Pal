import CoreGraphics
import ImageIO
import PalDiagnostics
import SwiftUI

public struct BotAvatarView: View {
    private let spec: BotAvatarSpec
    private let size: CGFloat
    private let mood: AvatarMood
    private let animated: Bool
    private let outline: AvatarOutline?
    private let pointerReach: CGFloat
    private let eyeInk: AvatarColor?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var clock: AvatarMoodClock
    @State private var cache = AvatarContentCache()
    @State private var look = AvatarLook.zero

    public init(
        spec: BotAvatarSpec,
        size: CGFloat,
        mood: AvatarMood = .idle,
        animated: Bool = true,
        outline: AvatarOutline? = nil,
        pointerReach: CGFloat? = nil,
        eyeInk: AvatarColor? = nil
    ) {
        self.spec = spec
        self.size = size
        self.mood = mood
        self.animated = animated
        self.outline = outline
        self.eyeInk = eyeInk
        self.pointerReach = pointerReach ?? AvatarLook.defaultReach(size: size)
        _clock = State(initialValue: AvatarMoodClock(
            mood: mood,
            since: Date(),
            blinkDelay: AvatarBlink.delaySeconds(for: spec.blinkKey),
            loadingSeed: LoadingSequence.seed(for: spec.blinkKey),
            reduceMotion: false
        ))
    }

    private var activity: AvatarActivity {
        AvatarActivity(mood: mood, size: size, animated: animated, reduceMotion: reduceMotion)
    }

    public var body: some View {
        let content = cache.resolve(spec, colorScheme, eyeInk: eyeInk)
        let activity = self.activity
        let resolved = resolvedClock(solid: content.isSolid)
        AvatarStage(
            content: content,
            size: size,
            clock: activity.ticks(settling: resolved.isSettling(at: Date())) ? resolved : nil,
            staticPose: AvatarMotion.staticPose(mood),
            frameInterval: activity.frameInterval,
            outline: outline,
            reduceMotion: reduceMotion,
            look: look
        )
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.7), value: look)
        .allowsHitTesting(false)
        .frame(width: size, height: size)
        .modifier(PointerLook(look: $look, size: size, reach: pointerReach, tracks: activity.tracksPointer))
        .accessibilityHidden(true)
        .onChange(of: mood) { _, next in
            clock = resolvedClock(solid: cache.isSolid).changing(to: next, at: Date())
        }
    }

    private func resolvedClock(solid: Bool) -> AvatarMoodClock {
        var resolved = clock
        resolved.solidClips = solid
        resolved.restingBlinks = activity.blinksAtRest
        resolved.blinkDelay = AvatarBlink.delaySeconds(for: spec.blinkKey)
        resolved.loadingSeed = LoadingSequence.seed(for: spec.blinkKey)
        resolved.reduceMotion = reduceMotion
        return resolved
    }
}

final class AvatarContentCache {
    private let store: AvatarContentStore
    private var spec: BotAvatarSpec?
    private var scheme: ColorScheme?
    private var eyeInk: AvatarColor?
    private var content: AvatarContent?

    init(store: AvatarContentStore = .shared) {
        self.store = store
    }

    var isSolid: Bool { content?.isSolid ?? false }

    func resolve(_ spec: BotAvatarSpec, _ scheme: ColorScheme, eyeInk: AvatarColor?) -> AvatarContent {
        if let content, self.spec == spec, self.scheme == scheme, self.eyeInk == eyeInk { return content }
        let built = store.content(for: spec, scheme: scheme, eyeInk: eyeInk)
        self.spec = spec
        self.scheme = scheme
        self.eyeInk = eyeInk
        content = built
        return built
    }
}

private struct PointerLook: ViewModifier {
    @Binding var look: AvatarLook
    let size: CGFloat
    let reach: CGFloat
    let tracks: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        if tracks {
            content.background {
                Color.clear
                    .frame(width: size + 2 * reach, height: size + 2 * reach)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): look = .toward(point, size: size, reach: reach)
                        case .ended: look = look.released
                        }
                    }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct AvatarStage: View, @MainActor Animatable {
    let content: AvatarContent
    let size: CGFloat
    let clock: AvatarMoodClock?
    let staticPose: AvatarPose
    let frameInterval: TimeInterval
    let outline: AvatarOutline?
    let reduceMotion: Bool
    var look: AvatarLook

    var animatableData: AvatarLook {
        get { look }
        set { look = newValue }
    }

    var body: some View {
        if let clock {
            TimelineView(AvatarSchedule(clock: clock, frameInterval: frameInterval)) { context in
                PalPerf.interval("avatar.frame") { frame(pose: clock.pose(at: context.date)) }
            }
        } else {
            frame(pose: staticPose)
        }
    }

    private func frame(pose: AvatarPose) -> some View {
        AvatarFrame(content: content, pose: pose, size: size, look: look, outline: outline, reduceMotion: reduceMotion)
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
    case solid(AvatarSolid)
    case photo(CGImage)

    init(_ spec: BotAvatarSpec) {
        switch spec {
        case .photo(let photo):
            if let image = Self.decode(photo.data) {
                self = .photo(image)
            } else {
                self = Self.content(photo.fallback)
            }
        case .shape(let shape):
            self = Self.content(shape)
        }
    }

    static func content(_ shape: ShapeAvatar) -> AvatarContent {
        switch shape {
        case .blob, .classic: .solid(AvatarSolid(rig(shape)))
        case .sigil: .rig(rig(shape))
        }
    }

    var isSolid: Bool {
        if case .solid = self { return true }
        return false
    }

    func eyeInked(_ ink: AvatarColor) -> AvatarContent {
        switch self {
        case .rig(var rig):
            rig.eyes.fill = ink
            return .rig(rig)
        case .solid(let solid): return .solid(solid.eyeInked(ink))
        case .photo: return self
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
    var look = AvatarLook.zero
    var outline: AvatarOutline?
    var reduceMotion = false

    var body: some View {
        switch content {
        case .rig(let rig):
            AvatarCanvas(rig: rig, pose: pose, size: size, look: look, outline: outline, reduceMotion: reduceMotion)
        case .solid(let solid):
            SolidCanvas(solid: solid, pose: pose, size: size, look: look, outline: outline, reduceMotion: reduceMotion)
        case .photo(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .scaleEffect(x: pose.bodyScaleX, y: pose.bodyScaleY)
                .rotationEffect(.degrees(pose.bodyRotation + photoLean))
                .offset(x: pose.bodyX * size, y: pose.bodyY * size)
                .opacity(pose.opacity)
        }
    }

    private var photoLean: Double {
        reduceMotion ? 0 : AvatarRig.leanDegrees * look.x * look.amount
    }
}

private struct AvatarCanvas: View {
    let rig: AvatarRig
    let pose: AvatarPose
    let size: CGFloat
    let look: AvatarLook
    let outline: AvatarOutline?
    let reduceMotion: Bool

    var body: some View {
        let inset = (size * 0.3).rounded()
        let side = size + 2 * inset
        Canvas { context, _ in
            PalPerf.interval("avatar.canvas.draw") {
                AvatarPainter(rig: rig, size: size, inset: inset, look: look, outline: outline)
                    .paint(rig.posed(pose, look: look, reduceMotion: reduceMotion), in: &context)
            }
        }
        .frame(width: side, height: side)
        .frame(width: size, height: size)
    }
}

private struct AvatarPainter {
    let rig: AvatarRig
    let size: CGFloat
    let inset: CGFloat
    let look: AvatarLook
    let outline: AvatarOutline?

    private var scale: CGFloat { size / max(rig.viewBox.width, rig.viewBox.height) }

    private var placement: CGAffineTransform { rig.placement(size: size, inset: inset) }

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
        if let outline { paintOutline(outline, in: &context) }
        if rig.clipsToViewBox {
            context.clip(to: Path(CGRect(x: inset, y: inset, width: size, height: size)))
        }
        for element in rig.body {
            draw(element, in: &context)
        }
        let eyes = rig.eyePaths(pose, look: look).map { $0.applying(place) }
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

    private func paintOutline(_ outline: AvatarOutline, in context: inout GraphicsContext) {
        var silhouette = Path()
        for element in rig.body { silhouette.addPath(element.path.applying(placement)) }
        let style = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        context.drawLayer { layer in
            layer.stroke(silhouette, with: .color(outline.color), style: style(2 * (outline.gap + outline.thickness)))
            layer.fill(silhouette, with: .color(outline.color))
            layer.blendMode = .destinationOut
            layer.stroke(silhouette, with: .color(.black), style: style(2 * outline.gap))
            layer.fill(silhouette, with: .color(.black))
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
