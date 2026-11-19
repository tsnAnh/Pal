#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

enum DropOverlayTint {
    case bot(Color)
    case neutral

    static func resolve(accent: BotAccent?) -> DropOverlayTint {
        accent.map { .bot(BubblePalette.ink(accent: $0)) } ?? .neutral
    }

    var isNeutral: Bool {
        if case .neutral = self { true } else { false }
    }

    var fill: Color { color.opacity(isNeutral ? 0.08 : 0.10) }
    var border: Color { color.opacity(isNeutral ? 0.45 : 0.8) }
    var glyph: Color { color }
    var badge: Color { color }

    private var color: Color {
        if case .bot(let color) = self { color } else { PalTokens.textSecondary }
    }
}

enum DropOverlayCopy {
    static func title(count: Int, botName: String) -> String {
        count > 1
            ? String(localized: "Drop \(count) files to attach to \(botName)")
            : String(localized: "Drop to attach to \(botName)")
    }

    static var subtitle: String { String(localized: "Images and files") }
}

struct DropOverlay: View {
    let targeting: DropTargeting
    let botName: String
    let accent: BotAccent?

    private static let glyph = "tray.and.arrow.down"
    private static let inset: CGFloat = 8

    var body: some View {
        if targeting.isTargeted {
            let tint = DropOverlayTint.resolve(accent: accent)
            let shape = RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
            ZStack {
                shape.fill(tint.fill)
                shape.strokeBorder(tint.border, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                card(tint: tint)
            }
            .padding(Self.inset)
            .allowsHitTesting(false)
            .accessibilityIdentifier("composerDropTarget")
        }
    }

    private func card(tint: DropOverlayTint) -> some View {
        VStack(spacing: 10) {
            Image(systemName: Self.glyph)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(tint.glyph)
                .overlay(alignment: .topTrailing) { countBadge(tint: tint) }
            VStack(spacing: 2) {
                Text(DropOverlayCopy.title(count: targeting.itemCount, botName: botName))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PalTokens.textPrimary)
                Text(DropOverlayCopy.subtitle)
                    .font(.caption)
                    .foregroundStyle(PalTokens.textSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func countBadge(tint: DropOverlayTint) -> some View {
        if targeting.itemCount > 1 {
            Text("\(targeting.itemCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(tint.badge, in: Capsule())
                .offset(x: 12, y: -8)
        }
    }
}
#endif
