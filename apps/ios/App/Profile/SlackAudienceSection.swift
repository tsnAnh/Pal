import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct SlackAudienceSection: View {
    let members: ChatMembersModel
    let name: String
    let workspace: String

    @State private var picking: ChatPeopleSearchModel?

    private var audience: ChatAudienceWire? { members.audience }
    private var policy: ChatAudiencePolicy? { audience?.policy }

    var body: some View {
        SlackGroup(
            caption: String(localized: "Who can talk to \(name)"),
            footer: String(localized: "People other than you can chat with \(name) and ask questions.")
                + " " + String(localized: "Anything that changes things on your computer or accounts waits for your OK."),
            identifier: "slackAudience"
        ) {
            SlackChoiceRow(
                icon: "person", title: String(localized: "Only me"),
                detail: String(localized: "\(name) answers only you. Others get a short note that it's private."),
                isSelected: policy == .ownerOnly, identifier: "slackAudienceOwnerOnly"
            ) { Task { await members.setPolicy(.ownerOnly) } }
            PalHairline()
            SlackChoiceRow(
                icon: "person.3", title: String(localized: "Everyone in \(workspace)"),
                detail: String(localized: "Anyone in the workspace can message or mention \(name)."),
                isSelected: policy == .workspace, identifier: "slackAudienceWorkspace"
            ) { Task { await members.setPolicy(.workspace) } }
            if policy == .workspace { guests }
            PalHairline()
            SlackChoiceRow(
                icon: "person.2", title: String(localized: "Specific people"), detail: String(localized: "You, plus the people you pick."),
                isSelected: policy == .listed, identifier: "slackAudienceListed"
            ) { Task { await members.setPolicy(.listed) } }
            if policy == .listed { specificPeople }
        }
        .disabled(audience == nil || members.isSaving)
        .macSheet(item: $picking, size: .full) { search in
            SlackPeoplePicker(search: search, name: name, workspace: workspace) { picking = nil }
        }
    }

    private var guests: some View {
        VStack(spacing: 0) {
            PalHairline()
            SettingsRow.toggle(
                String(localized: "Include guests"),
                subtitle: String(localized: "Guests are invited to only some channels, not the whole workspace."),
                isOn: Binding(
                    get: { audience?.includeRestricted ?? false },
                    set: { value in Task { await members.setIncludeRestricted(value) } }
                ),
                accessibilityIdentifier: "slackAudienceGuests"
            )
        }
    }

    @ViewBuilder
    private var specificPeople: some View {
        let chosen = audience?.members ?? []
        if chosen.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nobody picked yet. Until you add someone, only you can talk to \(name).")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("slackAudienceEmpty")
                addButton(title: String(localized: "Add people"))
            }
            .padding([.horizontal, .bottom], PalMetrics.screenMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 32)
        } else {
            KanbanFlow(spacing: 8) {
                ForEach(chosen) { member in chip(member) }
                addButton(title: String(localized: "Add"))
            }
            .padding([.horizontal, .bottom], PalMetrics.screenMargin)
            .padding(.leading, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ member: ChatAudienceMemberWire) -> some View {
        HStack(spacing: 6) {
            PersonBadge(name: member.name, size: 22)
            Text(member.name).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textPrimary).lineLimit(1)
            Button { Task { await members.removeMember(member.id) } } label: {
                PalIcon("xmark", ink: .tertiary).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(member.name)"))
            .accessibilityIdentifier("slackAudienceRemove-\(member.id)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(PalTokens.chipFill, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slackAudienceMember-\(member.id)")
    }

    private func addButton(title: String) -> some View {
        Button { picking = ChatPeopleSearchModel(members: members, picked: audience?.members ?? []) } label: {
            Label(title, palIcon: "plus")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("slackAudienceAdd")
    }
}
