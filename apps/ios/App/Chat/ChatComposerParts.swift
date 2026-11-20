import PalChat
import PalDesign
import SwiftUI

struct CompletionRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let header: String?
}

struct CompletionList: View {
    let rows: [CompletionRow]
    let emptyText: LocalizedStringKey?
    let selection: String?
    let listIdentifier: String
    let rowIdentifierPrefix: String
    var showsContainer = true
    let pick: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty, let emptyText {
                        Text(emptyText)
                            .font(.system(size: 13))
                            .foregroundStyle(PalTokens.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("\(listIdentifier)Empty")
                    }
                    ForEach(rows) { row in
                        if let header = row.header {
                            Text(header)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PalTokens.textTertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        Button { pick(row.id) } label: { rowView(row) }
                            .buttonStyle(.plain)
                            .background(row.id == selection ? PalTokens.selected : Color.clear)
                            .id(row.id)
                            .accessibilityIdentifier(rowIdentifierPrefix + row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxHeight: 240)
        .background(showsContainer ? PalTokens.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(showsContainer ? PalTokens.panelBorder : Color.clear, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(listIdentifier)
    }

    private func rowView(_ row: CompletionRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
            if !row.subtitle.isEmpty {
                Text(row.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct ReplyBar: View {
    let target: ReplyTarget
    let botName: String
    let accent: BotAccent?
    let cancel: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var title: Text {
        switch target.author {
        case .you: Text("Replying to yourself")
        case .bot: Text("Replying to \(botName)")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(accent?.accent ?? PalTokens.inverseFill)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                Text(target.quote)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                PalIcon("xmark", ink: .secondary)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .minimumHitTarget(visual: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel reply"))
            .help(Text("Cancel reply"))
            .accessibilityIdentifier("replyCancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replyBar")
    }
}

struct AttachmentTray: View {
    let attachments: [PendingAttachment]
    let remove: (UUID) -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    chip(attachment)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("attachmentTray")
    }

    private func chip(_ attachment: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            content(attachment)
                .frame(width: 60, height: 60)
                .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { overlay(attachment) }
            Button { remove(attachment.id) } label: {
                ZStack {
                    PalIcon("circle.fill", ink: .custom(Color(theme.palette.circleButtonFill)))
                        .font(.system(size: 20))
                    PalIcon("xmark")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("Remove \(attachment.name)"))
            .help(Text("Remove \(attachment.name)"))
            .accessibilityIdentifier("removeAttachment")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachmentChip")
        .help(attachment.failureReason ?? attachment.name)
    }

    @ViewBuilder
    private func content(_ attachment: PendingAttachment) -> some View {
        if let data = attachment.thumbnail, let image = PlatformImage(data: data) {
            Image(platformImage: image).resizable().scaledToFill()
                .accessibilityIdentifier("attachmentThumbnail")
        } else {
            VStack(spacing: 4) {
                PalIcon("doc", ink: .secondary).font(.system(size: 20))
                Text(attachment.name).font(.caption2).lineLimit(1).padding(.horizontal, 4)
            }
            .foregroundStyle(Color(theme.palette.textSecondary))
        }
    }

    @ViewBuilder
    private func overlay(_ attachment: PendingAttachment) -> some View {
        switch attachment.state {
        case .uploading:
            ZStack {
                PalTokens.content.opacity(0.55)
                ProgressView().controlSize(.small).tint(PalTokens.textSecondary)
            }
            .accessibilityIdentifier("attachmentUploading")
        case .failed(let reason):
            ZStack {
                PalTokens.content.opacity(0.75)
                PalIcon("exclamationmark.circle")
                    .font(.system(size: 17, weight: .medium))
            }
            .accessibilityLabel(Text(reason))
            .accessibilityIdentifier("attachmentFailed")
        case .ready:
            EmptyView()
        }
    }
}
