import PalChat
import PalDesign
import SwiftUI

struct ApprovalsView: View {
    let bots: [HeldDraftBot]
    let close: () -> Void

    @Environment(\.heldDrafts) private var drafts

    var body: some View {
        if let drafts { ApprovalsContent(drafts: drafts, bots: bots, close: close) }
    }
}

private struct ApprovalsContent: View {
    let drafts: HeldDraftsModel
    let bots: [HeldDraftBot]
    let close: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var opened: Opened?

    private struct Opened: Identifiable {
        let entry: HeldDraftEntry
        let model: HeldDraftSheetModel
        var id: String { entry.id }
    }

    private var entries: [HeldDraftEntry] {
        let names = Set(bots.map(\.name))
        return drafts.entries.filter { names.contains($0.bot.name) }
    }

    var body: some View {
        chrome
            .task(id: bots) { await drafts.load(bots: bots) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("approvalsScreen")
    }

    private func open(_ entry: HeldDraftEntry) {
        opened = Opened(entry: entry, model: drafts.cardModel(for: entry))
    }

    private func closeDetail() {
        opened = nil
        Task { await drafts.load(bots: bots) }
    }

    @ViewBuilder
    private var page: some View {
        if let opened {
            ScrollView {
                HeldDraftSheet(model: opened.model)
                    .padding(.horizontal, ChatMetrics.edgeMargin)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { rows }
                    .padding(.horizontal, ChatMetrics.edgeMargin)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        if entries.isEmpty {
            if drafts.phase == .ready {
                ContentUnavailableView {
                    Label("Nothing is waiting", palIcon: "checkmark")
                } description: {
                    Text("Messages your bots hold for you appear here.")
                }
                .accessibilityIdentifier("approvalsEmpty")
            } else {
                ProgressView().padding(.top, 40).accessibilityIdentifier("approvalsLoading")
            }
        }
        ForEach(entries) { entry in
            ApprovalRow(entry: entry, showsBot: bots.count > 1) { open(entry) }
        }
        if !drafts.unreachable.isEmpty {
            Text("Couldn't check \(drafts.unreachable.map(\.displayName).joined(separator: ", ")). Reopen Approvals to try again.")
                .font(.footnote)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .accessibilityIdentifier("approvalsUnreachable")
        }
    }

    @ViewBuilder
    private var chrome: some View {
        #if os(iOS)
        if let opened {
            SheetChrome(
                title: opened.entry.bot.displayName,
                leading: .back,
                titleAlignment: .afterLeadingButton,
                accessibilityIdentifier: "approvalDetail",
                onLeading: closeDetail,
                content: { page }
            )
        } else {
            SheetChrome(
                title: String(localized: "Approvals"),
                titleAlignment: .afterLeadingButton,
                accessibilityIdentifier: "approvalsList",
                onLeading: close,
                content: { page }
            )
        }
        #else
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if opened != nil {
                    Button("Back", action: closeDetail)
                        .glassButtonStyle()
                        .accessibilityIdentifier("approvalDetailBack")
                }
                Text(opened?.entry.bot.displayName ?? String(localized: "Approvals"))
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .padding(.leading, PalMetrics.macPanelTitleClearance)
            .frame(height: 49)
            page
        }
        #endif
    }
}

private struct ApprovalRow: View {
    let entry: HeldDraftEntry
    let showsBot: Bool
    let open: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var subtitle: String {
        showsBot ? "\(entry.draft.channelName), \(entry.bot.displayName)" : entry.draft.channelName
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.draft.recipientName)
                    .font(.headline)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                Text(entry.statusLine())
                    .font(.footnote)
                    .foregroundStyle(Color(theme.palette.textTertiary))
            }
            .frame(maxWidth: .infinity, minHeight: ChatMetrics.minimumHitTarget, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(entry.draft.recipientName), \(subtitle), \(entry.statusLine())"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("approvalRow-\(entry.id)")
    }
}
