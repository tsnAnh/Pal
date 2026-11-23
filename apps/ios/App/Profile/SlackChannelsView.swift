import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct SlackChannelsView: View {
    let chat: ChatInstallModel
    let name: String

    @State private var search = ""

    private var rows: [ChatSpaceRow] {
        chat.spaces.filter { search.isEmpty || $0.space.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
            HStack(spacing: 8) {
                PalIcon("magnifyingglass", ink: .tertiary).accessibilityHidden(true)
                PalTextField(String(localized: "Search channels"), text: $search)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("slackChannelSearch")
            }
            .padding(.vertical, PalMetrics.captionToCardGap)
            .padding(.horizontal, PalMetrics.screenMargin)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            SlackCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    if offset > 0 { PalHairline() }
                    channel(row)
                }
            }
            ForEach(rows.filter { $0.invite != nil }) { row in invite(row) }
            SetupQuietButton(title: String(localized: "Check again"), identifier: "slackRefreshChannels") {
                Task { await chat.refreshSpaces() }
            }
        }
        .accessibilityIdentifier("slackChannels")
    }

    private func channel(_ row: ChatSpaceRow) -> some View {
        let isOn = row.status == .live || row.status == .joining
        return Button {
            if !isOn { Task { await chat.join(row.id) } }
        } label: {
            HStack(spacing: 12) {
                checkbox(isOn)
                VStack(alignment: .leading, spacing: 2) {
                    Label(row.space.name, palIcon: row.space.kind == .private ? "lock" : "number")
                        .hermesText(.rowTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(PalTokens.textPrimary)
                    if let note = note(row) {
                        Text(note).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(PalMetrics.screenMargin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(isOn ? String(localized: "On") : String(localized: "Off")))
        .accessibilityIdentifier("slackChannel-\(row.id)")
    }

    private func checkbox(_ isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isOn ? PalTokens.inverseFill : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isOn ? PalTokens.inverseFill : PalTokens.borderStrong, lineWidth: 1.5)
                if isOn { PalIcon("checkmark", ink: .onInverseFill).font(.system(size: 11, weight: .bold)) }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    private func note(_ row: ChatSpaceRow) -> String? {
        switch row.status {
        case .live, .available: nil
        case .joining: String(localized: "Joining")
        case .needsInvite:
            row.invite == nil
                ? String(localized: "Private: tap to get the invite message.")
                : String(localized: "Private: invite \(name) there. Copy the message below.")
        }
    }

    @ViewBuilder
    private func invite(_ row: ChatSpaceRow) -> some View {
        if let invite = row.invite {
            VStack(alignment: .leading, spacing: 8) {
                if let text = invite.copyText {
                    StepCopyCard(label: String(localized: "Paste in the private channel"), value: text, identifier: "slackInvite-\(row.id)")
                }
                if let link = invite.link.flatMap(URL.init(string:)) {
                    SetupButton(title: String(localized: "Open in Slack"), identifier: "slackOpenChannel-\(row.id)") { ExternalLink.open(link) }
                }
            }
        }
    }
}
