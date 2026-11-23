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

private struct RoomActionButton: View {
    let title: String
    let isBusy: Bool
    let isEnabled: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(title)
            }
        }
        .glassButtonStyle(prominent: true)
        .disabled(isBusy || !isEnabled)
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
                RoomActionButton(
                    title: String(localized: "Create"),
                    isBusy: model.isCreating,
                    isEnabled: model.canCreate,
                    identifier: "roomCreateButton"
                ) { Task { await create() } }
            },
            content: { form }
        )
        .palEscapePolicy(model.isCreating ? .blocked(.inFlight) : EscapePolicy(blocking: .unsavedInput, when: !model.name.isEmpty || !model.selected.isEmpty))
    }

    @ViewBuilder
    private var form: some View {
        #if os(macOS)
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
                    ForEach(rooms.seatableBots) { bot in
                        pickRow(bot)
                            .padding(.horizontal, PalMetrics.rowInset)
                            .frame(minHeight: PalMetrics.rowMinimumHeight)
                    }
                }
                failureNote
                    .padding(.horizontal, PalMetrics.screenMargin)
                    .padding(.top, PalMetrics.captionToCardGap)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
        #else
        List {
            Section {
                TextField("", text: $model.name, prompt: Text(String(localized: "Group chat name")))
                    .focused($nameFocused)
                    .accessibilityLabel(Text("Group chat name"))
                    .accessibilityIdentifier("roomNameField")
                    .listRowBackground(rowFill)
            }
            Section {
                ForEach(rooms.seatableBots) { bot in pickRow(bot) }
            } header: {
                Text("Bots (2 to 6)")
                    .hermesText(.sectionCaption)
                    .foregroundStyle(Color(theme.palette.sectionCaption))
                    .textCase(nil)
                    .accessibilityIdentifier("createRoomBotsCaption")
            } footer: {
                failureNote
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    @ViewBuilder
    private var failureNote: some View {
        if let failure = model.failure {
            Text(failure)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .accessibilityIdentifier("createRoomFailure")
        }
    }

    private var rowFill: Color { Color(theme.palette.groupedCard) }

    private func pickRow(_ bot: BotRow) -> some View {
        let isSelected = model.selected.contains(bot.name)
        return Button { model.toggle(bot.name) } label: {
            HStack(spacing: 12) {
                BotAvatarView(spec: bot.spec, size: 30 * 1.15).frame(width: 30, height: 30)
                Text(bot.displayName)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    PalIcon("checkmark").accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowFill)
        .accessibilityIdentifier("roomPick-\(bot.name)")
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
    private var dismiss = SheetDismiss()

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
                RoomActionButton(
                    title: String(localized: "Save"),
                    isBusy: isRenaming,
                    isEnabled: canSaveName,
                    identifier: "roomRenameSave"
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
