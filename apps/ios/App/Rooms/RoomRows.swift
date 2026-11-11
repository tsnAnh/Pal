import HermesBotProfile
import HermesDesign
import HermesProtocol
import SwiftUI

struct RoomEventRow: View {
    let event: RoomEvent
    let room: Room
    let roster: RosterModel
    let canDownload: Bool
    let download: (RoomAttachment, RoomEvent) -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if let notice = event.notice {
            RoomNoticeRow(notice: notice, member: room.member(event.memberID))
        } else if event.isMessage {
            message
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 4) {
            if event.isFromMember {
                RoomAuthorLabel(name: event.author(in: room) ?? "", member: room.member(event.actorID), roster: roster)
                    .padding(.top, 10)
                if !event.text.isEmpty { AssistantBubble(text: event.text, highlight: "", isCurrentMatch: false) }
            } else if !event.text.isEmpty {
                UserBubble(text: event.text, delivery: .sent, accent: nil, highlight: "", isCurrentMatch: false, retry: { _ in })
                    .padding(.top, 10)
            }
            ForEach(event.attachments) { attachment in
                RoomAttachmentChip(attachment: attachment, canDownload: canDownload) { download(attachment, event) }
                    .frame(maxWidth: .infinity, alignment: event.isFromMember ? .leading : .trailing)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct RoomAuthorLabel: View {
    let name: String
    let member: RoomMember?
    let roster: RosterModel

    var body: some View {
        HStack(spacing: 6) {
            RoomMemberAvatar(member: member, roster: roster, size: 18)
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(PalTokens.textSecondary)
        }
        .padding(.leading, 6)
        .accessibilityIdentifier("roomAuthor")
    }
}

struct RoomMemberAvatar: View {
    let member: RoomMember?
    let roster: RosterModel
    let size: CGFloat

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if let member, let bot = roster.bot(named: member.profile) {
            BotAvatarView(spec: bot.spec, size: size * 1.15)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(Color(theme.palette.chipSelectedFill))
                .frame(width: size, height: size)
                .overlay(Text(String((member?.displayName ?? "?").prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .semibold)))
        }
    }
}

struct RoomNoticeRow: View {
    let notice: RoomNotice
    let member: RoomMember?

    private var text: String {
        let name = member?.displayName
        switch notice {
        case .turnFailed: return name.map { String(localized: "\($0) couldn't finish this reply.") } ?? String(localized: "A reply failed.")
        case .turnCancelled: return name.map { String(localized: "\($0)'s reply was stopped.") } ?? String(localized: "A reply was stopped.")
        case .turnDeferred: return name.map { String(localized: "\($0) will reply later.") } ?? String(localized: "A reply is waiting.")
        case .memberUnavailable: return name.map { String(localized: "\($0) isn't available.") } ?? String(localized: "A bot isn't available.")
        case .stopRequested: return String(localized: "Stopped the bots.")
        case .disbanded: return String(localized: "This group chat has ended.")
        case .authorityLost: return String(localized: "This group chat lost its connection to its host.")
        }
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(PalTokens.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityIdentifier("roomNotice")
    }
}

struct RoomAttachmentChip: View {
    let attachment: RoomAttachment
    let canDownload: Bool
    let download: () -> Void

    var body: some View {
        Button(action: download) {
            Label(attachment.name, systemImage: attachment.kind == "image" ? "photo" : attachment.kind == "pdf" ? "doc.richtext" : "doc")
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(PalTokens.selected, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canDownload)
        .accessibilityLabel(Text("Download \(attachment.name)"))
        .accessibilityIdentifier("roomAttachment")
    }
}

struct RoomActionCard: View {
    let action: RoomPendingAction
    let room: Room
    let isBusy: Bool
    let approve: (Bool) -> Void
    let retry: () -> Void
    let discard: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var name: String { room.member(action.memberID)?.displayName ?? action.memberID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.leading, 6)
            if action.isApproval {
                if action.canAllowOnce || action.canDeny {
                    ApprovalCard(prompt: prompt) { choice in
                        guard !isBusy else { return }
                        approve(choice == "once")
                    }
                    .disabled(isBusy)
                }
            } else {
                HStack(spacing: 10) {
                    Button("Retry", action: retry).buttonStyle(.glass).accessibilityIdentifier("roomRetry")
                    Button("Discard", role: .destructive, action: discard).buttonStyle(.glass).accessibilityIdentifier("roomDiscard")
                }
                .disabled(isBusy)
            }
        }
        .accessibilityIdentifier("roomAction-\(action.kind)")
    }

    private var prompt: PendingPrompt {
        PendingPrompt(
            kind: .approval,
            promptID: action.requestID ?? "",
            executionGeneration: action.executionGeneration,
            choices: ["once", "deny"].filter { $0 == "once" ? action.canAllowOnce : action.canDeny },
            command: action.shownCommand.isEmpty ? nil : action.shownCommand,
            description: action.description.isEmpty ? nil : action.description
        )
    }
}

struct RoomMemberStrip: View {
    let room: Room
    let roster: RosterModel
    let busy: Set<String>
    let mention: (RoomMember) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(room.members) { member in
                    Button { mention(member) } label: {
                        HStack(spacing: 6) {
                            RoomMemberAvatar(member: member, roster: roster, size: 18)
                            Text(member.displayName).font(.footnote).lineLimit(1)
                            if busy.contains(member.memberID) { ProgressView().controlSize(.mini) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PalTokens.selected, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(busy.contains(member.memberID) ? "\(member.displayName), working" : "\(member.displayName)"))
                    .accessibilityHint(Text("Mentions this bot"))
                    .accessibilityIdentifier("roomMember-\(member.memberID)")
                }
            }
            .padding(.horizontal, ChatMetrics.edgeMargin)
        }
    }
}
