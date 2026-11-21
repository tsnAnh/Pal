import PalDesign
import SwiftUI

extension View {
    func signInBackdrop(gathered: Bool, ring: Color) -> some View {
        backgroundPreferenceValue(SignInLineupKey.self) { lineup in
            SignInBackdrop(gathered: gathered, ring: ring, lineup: lineup)
                .ignoresSafeArea()
        }
    }
}

struct SignInLineupSlot: View {
    let gathered: Bool

    var body: some View {
        Color.clear
            .frame(width: SignInFloater.lineupWidth, height: gathered ? SignInMetrics.lineupDiameter : 0)
            .anchorPreference(key: SignInLineupKey.self, value: .bounds) { $0 }
            .accessibilityHidden(true)
    }
}

private struct SignInLineupKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct SignInBackdrop: View {
    let gathered: Bool
    let ring: Color
    let lineup: Anchor<CGRect>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let row = lineup.map { proxy[$0] }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || gathered)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(SignInFloater.all) { floater in
                        let floating = floater.position(in: proxy.size, at: time)
                        SignInFloaterView(
                            floater: floater,
                            floating: floating,
                            slot: row.map(floater.slot(in:)) ?? floating,
                            floatingOpacity: floater.opacity(at: time),
                            ring: ring,
                            gather: gathered ? 1 : 0
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SignInFloaterView: View, @MainActor Animatable {
    let floater: SignInFloater
    let floating: CGPoint
    let slot: CGPoint
    let floatingOpacity: Double
    let ring: Color
    var gather: Double

    var animatableData: Double {
        get { gather }
        set { gather = newValue }
    }

    var body: some View {
        let progress = CGFloat(gather)
        let scale = 1 + (SignInMetrics.lineupDiameter / floater.diameter - 1) * progress
        BotAvatarView(
            spec: floater.spec,
            size: floater.diameter / SignInMetrics.bodyFill,
            outline: progress > 0 ? AvatarOutline(gap: 0, thickness: SignInMetrics.lineupRing * progress / scale, color: ring) : nil,
            eyeInk: SignInMetrics.backdropEyes
        )
        .scaleEffect(scale)
        .position(
            x: floating.x + (slot.x - floating.x) * progress,
            y: floating.y + (slot.y - floating.y) * progress
        )
        .opacity(floatingOpacity + (1 - floatingOpacity) * gather)
    }
}

private struct SignInFloater: Identifiable {
    let id: Int
    let kind: String
    let color: String
    let anchor: CGPoint
    let diameter: CGFloat
    let drift: CGFloat
    let period: Double
    let fades: Bool

    var spec: BotAvatarSpec {
        BotAvatarSpec(name: "pal-\(id)", meta: BotAvatarMeta(shape: "blobatar:signin\(id):\(kind)", color: color, custom: true))
    }

    func position(in size: CGSize, at time: Double) -> CGPoint {
        let phase = Double(id) * 1.7
        let angle = time * 2 * .pi / period + phase
        return CGPoint(
            x: anchor.x * size.width + drift * cos(angle),
            y: anchor.y * size.height + drift * sin(angle * 0.8)
        )
    }

    func opacity(at time: Double) -> Double {
        guard fades else { return 1 }
        let wave = 0.5 + 0.5 * sin(time * 2 * .pi / (period * 0.6) + Double(id))
        return 0.12 + 0.88 * wave
    }

    func slot(in row: CGRect) -> CGPoint {
        let step = SignInMetrics.lineupDiameter - SignInMetrics.lineupOverlap
        return CGPoint(x: row.minX + SignInMetrics.lineupDiameter / 2 + CGFloat(id) * step, y: row.midY)
    }

    static var lineupWidth: CGFloat {
        let count = CGFloat(all.count)
        return count * SignInMetrics.lineupDiameter - (count - 1) * SignInMetrics.lineupOverlap
    }

    static let all: [SignInFloater] = [
        .init(id: 0, kind: "clover", color: "#0f7a3c", anchor: CGPoint(x: 0.28, y: 0.13), diameter: 100, drift: 10, period: 23, fades: true),
        .init(id: 1, kind: "round", color: "#ff1f8f", anchor: CGPoint(x: 0.64, y: 0.15), diameter: 72, drift: 9, period: 19, fades: false),
        .init(id: 2, kind: "round", color: "#8b4bff", anchor: CGPoint(x: 0.07, y: 0.30), diameter: 58, drift: 8, period: 21, fades: false),
        .init(id: 3, kind: "round", color: "#8a5a35", anchor: CGPoint(x: 0.97, y: 0.28), diameter: 62, drift: 8, period: 25, fades: false),
        .init(id: 4, kind: "round", color: "#ff8a00", anchor: CGPoint(x: 0.01, y: 0.48), diameter: 90, drift: 10, period: 27, fades: false),
        .init(id: 5, kind: "round", color: "#ff1f3d", anchor: CGPoint(x: 1.0, y: 0.47), diameter: 76, drift: 9, period: 24, fades: false),
        .init(id: 6, kind: "round", color: "#0bb39b", anchor: CGPoint(x: 0.89, y: 0.64), diameter: 68, drift: 9, period: 20, fades: true),
        .init(id: 7, kind: "boxy", color: "#1f6bff", anchor: CGPoint(x: 0.13, y: 0.68), diameter: 80, drift: 9, period: 22, fades: true),
    ]
}

struct SignInTone {
    let background: Color
    let buttonFill: Color
    let buttonRim: Color
    let primaryText: Color
    let secondaryText: Color
    let footnoteText: Color
    let errorText: Color

    static let dark = SignInTone(
        background: Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255),
        buttonFill: Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255),
        buttonRim: Color.white.opacity(0.12),
        primaryText: .white,
        secondaryText: Color(white: 0.6),
        footnoteText: Color(white: 0.36),
        errorText: Color(red: 1, green: 0.42, blue: 0.4)
    )

    static let light = SignInTone(
        background: Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255),
        buttonFill: .white,
        buttonRim: Color.black.opacity(0.08),
        primaryText: Color(white: 0.08),
        secondaryText: Color(white: 0.42),
        footnoteText: Color(white: 0.6),
        errorText: Color(red: 0.8, green: 0.15, blue: 0.12)
    )
}

enum SignInMetrics {
    static let backdropEyes = AvatarColor(css: "#111111")
    static let bodyFill: CGFloat = 0.76
    static let columnWidth: CGFloat = 430
    static let margin: CGFloat = 36
    static let titleSize: CGFloat = 38
    static let subtitleSize: CGFloat = 15
    static let subtitleWidth: CGFloat = 240
    static let titleToSubtitle: CGFloat = 12
    static let headingLift: CGFloat = 40
    static let buttonHeight: CGFloat = 47
    static let buttonTextSize: CGFloat = 15
    static let buttonGlyphSize: CGFloat = 24
    static let buttonGlyphInset: CGFloat = 14
    static let buttonToFootnote: CGFloat = 22
    static let compactTitleSize: CGFloat = 32
    static let compactHeadingTop: CGFloat = 28
    static let compactTitleToSubtitle: CGFloat = 6
    static let lineupDiameter: CGFloat = 38
    static let lineupOverlap: CGFloat = 10
    static let lineupRing: CGFloat = 3
    static let lineupToTitle: CGFloat = 18
    static let cardRadius: CGFloat = 24
    static let cardToMessage: CGFloat = 10
    static let messageToButton: CGFloat = 12
    static let errorSize: CGFloat = 13
    static let rowHeight: CGFloat = 47
    static let rowInset: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    static let rowGlyphSize: CGFloat = 15
    static let rowGlyphWidth: CGFloat = 20
    static let rowTextSize: CGFloat = 15
    static let checkingSize: CGFloat = 13
    static let checkingSpacing: CGFloat = 6
    static let busyOpacity: Double = 0.6
    static let secondarySpacing: CGFloat = 8
    static let orTop: CGFloat = 16
    static let footnoteSize: CGFloat = 11
    static let footnoteWidth: CGFloat = 300
    static let bottomPadding: CGFloat = 24
}
