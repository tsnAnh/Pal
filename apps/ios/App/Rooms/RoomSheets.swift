import PalBotProfile
import PalDesign
import PalRoster
import SwiftUI

private struct RoomNameField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    let identifier: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .padding(.horizontal, PalMetrics.rowInset)
            .frame(height: PalMetrics.rowMinimumHeight)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, PalMetrics.screenMargin)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
    }
}

struct CreateRoomSheet: View {
    @Bindable var rooms: RoomsModel
    let roster: RosterModel
    let router: AppRouter

    @State private var model = CreateRoomModel()
    @FocusState private var nameFocused: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: String(localized: "New Group Chat"),
            accessibilityIdentifier: "createRoomSheet",
            onLeading: { rooms.showsCreate = false },
            trailing: {
                PillButton(
                    String(localized: "Create"),
                    kind: model.canCreate ? .accent : .dimmed,
                    isBusy: model.isCreating,
                    accessibilityIdentifier: "roomCreateButton"
                ) { Task { await create() } }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        RoomNameField(
                            label: String(localized: "Group chat name"), prompt: String(localized: "Group chat name"),
                            text: $model.name, identifier: "roomNameField"
                        )
                        .focused($nameFocused)
                        SectionCaption(String(localized: "Bots (2 to 6)"), accessibilityIdentifier: "createRoomBotsCaption")
                            .padding(.top, PalMetrics.cardGap)
                            .padding(.bottom, PalMetrics.captionToCardGap)
                        GroupedCard(accessibilityIdentifier: "createRoomBots") {
                            ForEach(rooms.seatableBots) { bot in pickRow(bot) }
                        }
                        if let failure = model.failure {
                            Text(failure)
                                .hermesText(.rowSubtitle)
                                .foregroundStyle(Color(theme.palette.destructive))
                                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
                                .padding(.top, 10)
                                .accessibilityIdentifier("createRoomFailure")
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
        .interactiveDismissDisabled(model.isCreating)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    private func pickRow(_ bot: BotRow) -> some View {
        let isSelected = model.selected.contains(bot.name)
        return LeadingSettingsRow(
            title: bot.displayName,
            leadingSpacing: 12,
            accessibilityIdentifier: "roomPick-\(bot.name)",
            action: { model.toggle(bot.name) },
            leading: { BotAvatarView(spec: bot.spec, size: 30 * 1.15).frame(width: 30, height: 30) }
        )
        .overlay(alignment: .trailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(theme.palette.accentBlue))
                    .padding(.trailing, PalMetrics.rowInset)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func create() async {
        guard let room = await model.create(in: rooms, roster: roster) else { return }
        rooms.showsCreate = false
        router.openRoom(id: room.roomID)
    }
}

struct RoomDetailsSheet: View {
    let model: RoomModel
    let roster: RosterModel

    @State private var name = ""
    @State private var isRenaming = false
    @Environment(\.dismiss) private var dismiss

    private var canSaveName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.canRename && !isRenaming && !trimmed.isEmpty && trimmed != model.room.name
    }

    var body: some View {
        SheetChrome(
            title: String(localized: "Group Chat"),
            accessibilityIdentifier: "roomDetailsSheet",
            onLeading: { dismiss() },
            trailing: {
                PillButton(
                    String(localized: "Save"),
                    kind: canSaveName ? .accent : .dimmed,
                    isBusy: isRenaming,
                    accessibilityIdentifier: "roomRenameSave"
                ) { save() }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionCaption(String(localized: "Name"), accessibilityIdentifier: "roomDetailsNameCaption")
                            .padding(.bottom, PalMetrics.captionToCardGap)
                        RoomNameField(
                            label: String(localized: "Group chat name"), prompt: String(localized: "Group chat name"),
                            text: $name, identifier: "roomRenameField"
                        )
                        .disabled(!model.canRename)
                        .onSubmit { save() }
                        SectionCaption(String(localized: "Bots"), accessibilityIdentifier: "roomDetailsBotsCaption")
                            .padding(.top, PalMetrics.cardGap)
                            .padding(.bottom, PalMetrics.captionToCardGap)
                        GroupedCard(accessibilityIdentifier: "roomDetailsBots") {
                            ForEach(model.room.members) { member in
                                LeadingSettingsRow(
                                    title: member.displayName,
                                    value: "@\(member.handle)",
                                    leadingSpacing: 12,
                                    accessibilityIdentifier: "roomDetailsMember-\(member.memberID)",
                                    leading: { RoomMemberAvatar(member: member, roster: roster, size: 30) }
                                )
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
        .onAppear { name = model.room.name }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
    }

    private func save() {
        guard canSaveName else { return }
        isRenaming = true
        Task {
            let renamed = await model.rename(to: name)
            isRenaming = false
            if renamed { dismiss() }
        }
    }
}
