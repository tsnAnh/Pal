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
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
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
            if let project = row.project { KanbanChip(text: project, symbol: "folder") }
            if let bot = row.bot { KanbanChip(text: bot, symbol: "person") }
            if let kind = row.card.blockKind, !kind.isEmpty { KanbanChip(text: kind, symbol: "exclamationmark.circle", tone: .red) }
            if !row.pullRequests.isEmpty {
                KanbanChip(text: row.hasMergedPullRequest ? String(localized: "PR merged") : String(localized: "PR"), symbol: "arrow.triangle.pull", tone: .purple)
            }
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

struct KanbanTile: View {
    let row: KanbanCardRow
    let now: Date
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.card.title.isEmpty ? String(localized: "Untitled card") : row.card.title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                KanbanBadges(row: row, now: now)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PalMetrics.cardRadius)
                    .strokeBorder(isSelected ? PalTokens.textSecondary : PalTokens.panelBorder, lineWidth: isSelected ? 1.5 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: PalMetrics.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kanbanCard-\(row.card.taskID)")
    }
}

struct KanbanColumnView: View {
    let layout: KanbanColumnLayout
    let now: Date
    let selected: String?
    let width: CGFloat?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(layout.column.tone).frame(width: 8, height: 8)
                Text(layout.column.title).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
                Text(count).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kanbanColumnHeader-\(layout.column.id)")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(layout.rows) { row in
                        KanbanTile(row: row, now: now, isSelected: selected == row.card.taskID) { open(row.card.taskID) }
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
        .padding(10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanbanColumn-\(layout.column.id)")
    }

    @ViewBuilder
    private var emptyLabel: some View {
        if layout.total == 0 { Text("No cards") } else { Text("No matches") }
    }

    private var count: String {
        layout.rows.count == layout.total ? "\(layout.total)" : "\(layout.rows.count)/\(layout.total)"
    }
}
