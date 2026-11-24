#if os(macOS)
import PalChat
import PalDesign
import SwiftUI

struct MacApprovalsRow: View {
    let roster: RosterModel
    let router: AppRouter

    @Environment(\.heldDrafts) private var drafts
    @State private var hovering = false

    private var count: Int { drafts?.count(for: nil) ?? 0 }

    var body: some View {
        Button { router.presentApprovals() } label: {
            HStack(spacing: 8) {
                PalIcon("checkmark.circle", ink: .secondary)
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                Text("Approvals")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PalTokens.textSecondary)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PalTokens.textPrimary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hovering ? PalTokens.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .boundedToColumn()
        .onHover { hovering = $0 }
        .task(id: roster.bots.map(\.name)) { await drafts?.load(bots: roster.heldDraftBots()) }
        .accessibilityLabel(Text("Approvals"))
        .accessibilityValue(Text(count > 0 ? String(localized: "\(count) waiting") : String(localized: "None waiting")))
        .accessibilityIdentifier("approvalsRow")
    }
}
#endif
