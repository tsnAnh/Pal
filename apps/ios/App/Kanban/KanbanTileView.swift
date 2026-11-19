import PalDesign
import PalKanban
import PalTransport
import SwiftUI

extension KanbanColumn {
    var tone: Color {
        switch self {
        case .backlog: .gray
        case .ready: .blue
        case .inProgress: .orange
        case .blocked: .red
        case .review: .purple
        case .done: .green
        }
    }
}

struct KanbanFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct KanbanChip: View {
    let text: String
    var symbol: String?
    var tone: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { PalIcon(symbol, ink: .custom(tone)).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .hermesText(.footnoteCaption)
        .fontWeight(.medium)
        .foregroundStyle(tone)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tone.opacity(0.14), in: Capsule())
    }
}

struct KanbanBadges: View {
    let row: KanbanCardRow
    let now: Date

    var body: some View {
        KanbanFlow(spacing: 6) {
            KanbanChip(text: KanbanPresentation.statusTitle(row.card.status), tone: row.column.tone)
                .accessibilityIdentifier("kanbanState-\(row.card.taskID)")
            if let ref = row.ref { KanbanRefChip(ref: ref) }
            if let project = row.project { KanbanChip(text: project, symbol: "folder") }
            if row.bot != nil {
                KanbanAssignee(handle: row.bot, size: 16)
                    .hermesText(.footnoteCaption)
                    .fontWeight(.medium)
                    .foregroundStyle(PalTokens.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(PalTokens.chipFill, in: Capsule())
            }
            if let kind = row.card.blockKind, !kind.isEmpty { KanbanChip(text: kind, symbol: "exclamationmark.circle", tone: .red) }
            if let pullRequest = row.pullRequest { KanbanPullRequestChip(pullRequest: pullRequest, showsState: true) }
            if row.evidenceCount > 0 { KanbanChip(text: "\(row.evidenceCount)", symbol: "paperclip") }
            if let proof { KanbanChip(text: proof.text, symbol: proof.symbol, tone: proof.tone) }
            if let age = KanbanPresentation.age(since: KanbanPresentation.ageSource(row.card), now: now) {
                KanbanChip(text: age, symbol: "clock").opacity(0.8)
            }
        }
    }

    private struct Proof {
        let text: String
        let symbol: String
        let tone: Color
    }

    private var proof: Proof? {
        if let outcome = row.detail?.outcomeVerification, outcome.state == .verified {
            if outcome.verification == .independent {
                return Proof(text: String(localized: "Verified"), symbol: "checkmark.seal", tone: .green)
            }
            return Proof(text: String(localized: "Attested"), symbol: "checkmark.seal", tone: .secondary)
        }
        guard row.card.governed else { return nil }
        return Proof(text: String(localized: "Contract"), symbol: "doc.text", tone: .secondary)
    }
}

struct KanbanRoster: Sendable, Equatable {
    var names = KanbanBots()
    var specs: [String: BotAvatarSpec] = [:]

    func spec(_ handle: String) -> BotAvatarSpec {
        specs[handle] ?? BotAvatarSpec(name: handle, uiMeta: nil)
    }
}

extension EnvironmentValues {
    @Entry var kanbanRoster = KanbanRoster()
}

extension View {
    func kanbanGlass<S: Shape>(_ shape: S) -> some View {
        modifier(KanbanGlass(shape: shape))
    }
}

private struct KanbanGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(PalTokens.sidebar, in: shape)
                .overlay(shape.stroke(PalTokens.borderStrong, lineWidth: 0.5))
        } else {
            content.palGlass(shape, interactive: false)
        }
    }
}

struct KanbanAssignee: View {
    let handle: String?
    var size: CGFloat = 20

    @Environment(\.kanbanRoster) private var roster

    var body: some View {
        if let handle, let name = roster.names.name(for: handle) {
            HStack(spacing: 6) {
                BotAvatarView(spec: roster.spec(handle), size: size, animated: false)
                    .frame(width: size, height: size)
                Text(name).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kanbanAssignee-\(handle)")
        }
    }
}

struct KanbanPullRequestChip: View {
    let pullRequest: KanbanPullRequest
    var showsState = false

    @Environment(\.hermesTheme) private var theme

    private var tone: Color {
        switch pullRequest.state {
        case .open: .green
        case .merged: .purple
        case .checksFailing: Color(theme.palette.destructive)
        }
    }

    private var symbol: String {
        switch pullRequest.state {
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .checksFailing: "xmark.circle"
        }
    }

    private var stateTitle: String {
        switch pullRequest.state {
        case .open: String(localized: "Open")
        case .merged: String(localized: "Merged")
        case .checksFailing: String(localized: "Checks failing")
        }
    }

    private var number: String {
        pullRequest.number.map { "#\($0)" } ?? String(localized: "PR")
    }

    var body: some View {
        HStack(spacing: 3) {
            PalIcon(symbol, ink: .custom(tone)).font(.system(size: 9, weight: .semibold))
            Text(showsState ? "\(number) \(stateTitle)" : number).lineLimit(1)
        }
        .hermesText(.footnoteCaption)
        .fontWeight(.semibold)
        .foregroundStyle(tone)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(tone.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pull request \(number), \(stateTitle)"))
        .accessibilityIdentifier("kanbanPullRequest")
    }
}

struct KanbanTile: View {
    let row: KanbanCardRow
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                if let project = row.project, !project.isEmpty {
                    Text(project.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(PalTokens.textTertiary)
                        .lineLimit(1)
                }
                Text(row.displayTitle)
                    .hermesText(.chip)
                    .fontWeight(.medium)
                    .foregroundStyle(row.column == .done ? PalTokens.textSecondary : PalTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let ref = row.ref {
                    Text(ref)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PalTokens.textTertiary)
                        .lineLimit(1)
                }
                blockedNote
                footer
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? PalTokens.textSecondary : PalTokens.borderStrong, lineWidth: isSelected ? 1.5 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kanbanCard-\(row.card.taskID)")
    }

    @ViewBuilder
    private var blockedNote: some View {
        if row.column == .blocked, let kind = row.card.blockKind, !kind.isEmpty {
            Label(kind, palIcon: "exclamationmark.circle", ink: .destructive)
                .labelStyle(KanbanNoteLabelStyle())
                .hermesText(.footnoteCaption)
                .foregroundStyle(Color(theme.palette.destructive))
                .lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            KanbanAssignee(handle: row.bot)
            Spacer(minLength: 0)
            if row.column == .inProgress {
                Circle()
                    .fill(Color(theme.palette.workingDot))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(Text("Running"))
            }
            if let pullRequest = row.pullRequest { KanbanPullRequestChip(pullRequest: pullRequest) }
        }
        .hermesText(.footnoteCaption)
        .foregroundStyle(PalTokens.textSecondary)
        .padding(.top, 2)
    }
}

private struct KanbanNoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

struct KanbanColumnView: View {
    let layout: KanbanColumnLayout
    let selected: String?
    let width: CGFloat?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(layout.column.tone).frame(width: 8, height: 8)
                Text(layout.column.title).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                Spacer(minLength: 0)
                Text("\(layout.rows.count)")
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(PalTokens.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 22, minHeight: 18)
                    .background(PalTokens.chipFill, in: Capsule())
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kanbanColumnHeader-\(layout.column.id)")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(layout.rows) { row in
                        KanbanTile(row: row, isSelected: selected == row.card.taskID) { open(row.card.taskID) }
                    }
                    if layout.rows.isEmpty {
                        emptyLabel
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(PalTokens.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .padding(8)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity, alignment: .top)
        .kanbanGlass(RoundedRectangle(cornerRadius: PalMetrics.tileRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanbanColumn-\(layout.column.id)")
    }

    @ViewBuilder
    private var emptyLabel: some View {
        if layout.total == 0 { Text("No cards") } else { Text("No matches") }
    }
}
