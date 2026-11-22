import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct SlackReportSection: View {
    let members: ChatMembersModel
    let chat: ChatInstallModel
    let name: String

    private var report: ChatReportDestinationWire? { members.report }
    private var liveChannels: [ChatSpaceRow] { chat.spaces.filter { $0.status == .live } }

    var body: some View {
        SlackGroup(
            caption: String(localized: "Reports go to"),
            footer: String(localized: "When \(name) finishes something a coworker asked for, it tells you here."),
            identifier: "slackReport"
        ) {
            SlackChoiceRow(
                icon: "tray", title: String(localized: "Direct message to me"), detail: nil,
                isSelected: report?.kind == .ownerDirectMessages, identifier: "slackReportOwner"
            ) { Task { await members.setReport(.ownerDirectMessages) } }
            PalHairline()
            channelRow
        }
        .disabled(report == nil || members.isSaving)
    }

    private var channelRow: some View {
        let isSelected = report?.kind == .space
        return HStack(spacing: 12) {
            PalIcon("number", ink: .secondary).frame(width: 20).accessibilityHidden(true)
            Text("A channel").hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary)
            Spacer(minLength: 8)
            Menu {
                if liveChannels.isEmpty {
                    Text("\(name) isn't in any channels yet")
                } else {
                    ForEach(liveChannels) { row in
                        Button {
                            Task { await members.setReport(.space(id: row.id, name: row.space.name)) }
                        } label: {
                            if report?.spaceId == row.id {
                                Label(row.space.name, palIcon: "checkmark")
                            } else {
                                Text(row.space.name)
                            }
                        }
                        .accessibilityIdentifier("slackReportChannel-\(row.id)")
                    }
                    Divider()
                    Text("Only channels \(name) is in")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(isSelected ? "# \(report?.name ?? "")" : String(localized: "Choose")).lineLimit(1)
                    PalIcon("chevron.up.chevron.down", ink: .tertiary).font(.system(size: 11, weight: .semibold))
                }
                .hermesText(.rowValue)
                .foregroundStyle(PalTokens.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("slackReportChannelMenu")
            PalIcon("checkmark", ink: .primary).opacity(isSelected ? 1 : 0).accessibilityHidden(true)
        }
        .padding(PalMetrics.screenMargin)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slackReportChannel")
    }
}
