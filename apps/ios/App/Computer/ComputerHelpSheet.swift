import HermesDesign
import SwiftUI

enum ComputerHelpIcon {
    case symbol(String)
    case trackpad
}

struct ComputerHelpTopic: Identifiable {
    let id: String
    let icon: ComputerHelpIcon
    let title: String
    let detail: String
}

struct ComputerHelpSection: Identifiable {
    let id: String
    let caption: String
    let topics: [ComputerHelpTopic]
}

extension ComputerHelpSection {
    static let all: [ComputerHelpSection] = [
        ComputerHelpSection(id: "moving", caption: String(localized: "Moving around"), topics: [
            ComputerHelpTopic(
                id: "takeControl", icon: .symbol("eye"), title: String(localized: "Take control"),
                detail: String(localized: "You start out watching. Tap Take control in the bottom bar to click and type. When the Bot asks for help, you start in control.")
            ),
            ComputerHelpTopic(
                id: "scroll", icon: .symbol("arrow.up.arrow.down"), title: String(localized: "Scroll"),
                detail: String(localized: "Drag with two fingers.")
            ),
            ComputerHelpTopic(
                id: "clickAndDrag", icon: .symbol("location"), title: String(localized: "Click and drag"),
                detail: String(localized: "Tap to click where you tapped. One finger drags.")
            ),
            ComputerHelpTopic(
                id: "rightClick", icon: .symbol("list.bullet"), title: String(localized: "Right-click"),
                detail: String(localized: "Tap with two fingers, or press and hold.")
            ),
            ComputerHelpTopic(
                id: "zoom", icon: .symbol("plus.magnifyingglass"), title: String(localized: "Zoom in"),
                detail: String(localized: "Pinch to zoom. Zoomed in, two fingers pan instead of scrolling.")
            ),
        ]),
        ComputerHelpSection(id: "typing", caption: String(localized: "Typing and the clipboard"), topics: [
            ComputerHelpTopic(
                id: "type", icon: .symbol("keyboard"), title: String(localized: "Type"),
                detail: String(localized: "Tap the keyboard button in the bottom bar.")
            ),
            ComputerHelpTopic(
                id: "clipboard", icon: .symbol("list.clipboard"), title: String(localized: "Copy and paste"),
                detail: String(localized: "Tap the clipboard button in the bottom bar for Copy to Phone and Paste from Phone.")
            ),
        ]),
        ComputerHelpSection(id: "pointer", caption: String(localized: "When a pointer is easier"), topics: [
            ComputerHelpTopic(
                id: "trackpad", icon: .trackpad, title: String(localized: "Trackpad mode"),
                detail: String(localized: "Turn on from the ··· menu. Your finger moves the pointer; tap to click there, double-tap and hold to drag. Recenter pointer if it drifts.")
            ),
        ]),
        ComputerHelpSection(id: "handBack", caption: String(localized: "Handing it back"), topics: [
            ComputerHelpTopic(
                id: "imDone", icon: .symbol("arrow.uturn.backward"), title: String(localized: "I'm done"),
                detail: String(localized: "Tap I'm done when the Bot is waiting. Going back leaves it waiting.")
            ),
        ]),
    ]
}

struct ComputerHelpSheet: View {
    let onClose: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: String(localized: "Using the computer"),
            accessibilityIdentifier: "computerHelp",
            onLeading: onClose
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(ComputerHelpSection.all.enumerated()), id: \.element.id) { index, section in
                        SectionCaption(section.caption, accessibilityIdentifier: "computerHelpCaption-\(section.id)")
                            .padding(.top, index == 0 ? 0 : HermesMetrics.cardGap)
                            .padding(.bottom, HermesMetrics.captionToCardGap)
                        GroupedCard(separatorInset: HermesMetrics.iconRowSeparatorInset, accessibilityIdentifier: "computerHelpCard-\(section.id)") {
                            ForEach(section.topics) { topic in
                                ComputerHelpRow(topic: topic)
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .presentationDetents([.fraction(0.955)])
        .presentationDragIndicator(.hidden)
    }
}

private struct ComputerHelpRow: View {
    let topic: ComputerHelpTopic

    @Environment(\.hermesTheme) private var theme

    @ViewBuilder
    private var icon: some View {
        switch topic.icon {
        case .symbol(let name): Image(systemName: name).font(.system(size: 17, weight: .light))
        case .trackpad: TrackpadGlyph().frame(width: 16, height: 16)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: HermesMetrics.rowIconSpacing) {
            icon
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(width: HermesMetrics.rowIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HermesMetrics.rowTextSpacing) {
                Text(topic.title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                Text(topic.detail)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, HermesMetrics.rowIconLeadingInset)
        .padding(.trailing, HermesMetrics.rowInset)
        .padding(.vertical, HermesMetrics.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("computerHelpRow-\(topic.id)")
    }
}

private struct TrackpadGlyph: View {
    var body: some View {
        Canvas { context, size in
            let inset = 1.0
            var outline = Path()
            outline.move(to: CGPoint(x: size.width * 0.58, y: inset))
            outline.addLine(to: CGPoint(x: size.width * 0.22, y: inset))
            outline.addQuadCurve(to: CGPoint(x: inset, y: size.height * 0.22), control: CGPoint(x: inset, y: inset))
            outline.addLine(to: CGPoint(x: inset, y: size.height * 0.78))
            outline.addQuadCurve(to: CGPoint(x: size.width * 0.22, y: size.height - inset), control: CGPoint(x: inset, y: size.height - inset))
            outline.addLine(to: CGPoint(x: size.width * 0.78, y: size.height - inset))
            outline.addQuadCurve(to: CGPoint(x: size.width - inset, y: size.height * 0.78), control: CGPoint(x: size.width - inset, y: size.height - inset))
            outline.addLine(to: CGPoint(x: size.width - inset, y: size.height * 0.5))
            context.stroke(outline, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            let dot = CGRect(x: size.width * 0.72, y: 0, width: size.width * 0.26, height: size.width * 0.26)
            context.fill(Path(ellipseIn: dot), with: .foreground)
        }
    }
}
