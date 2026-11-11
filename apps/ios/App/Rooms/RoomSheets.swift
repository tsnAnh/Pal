import PalBotProfile
import PalDesign
import SwiftUI

struct CreateRoomSheet: View {
    @Bindable var rooms: RoomsModel
    let roster: RosterModel
    let router: AppRouter

    @State private var model = CreateRoomModel()
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Group chat name", text: $model.name)
                        .focused($nameFocused)
                        .accessibilityIdentifier("roomNameField")
                }
                Section {
                    ForEach(rooms.seatableBots) { bot in
                        Button { model.toggle(bot.name) } label: {
                            HStack(spacing: 12) {
                                BotAvatarView(spec: bot.spec, size: 30 * 1.15).frame(width: 30, height: 30)
                                Text(bot.displayName).foregroundStyle(PalTokens.textPrimary)
                                Spacer()
                                if model.selected.contains(bot.name) {
                                    Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selected.contains(bot.name) ? .isSelected : [])
                        .accessibilityIdentifier("roomPick-\(bot.name)")
                    }
                } header: {
                    Text("Bots (2 to 6)")
                } footer: {
                    if let failure = model.failure { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle(Text("New Group Chat"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { rooms.showsCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!model.canCreate)
                        .accessibilityIdentifier("roomCreateButton")
                }
            }
        }
        .interactiveDismissDisabled(model.isCreating)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
        .accessibilityIdentifier("createRoomSheet")
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
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Group chat name", text: $name)
                        .disabled(!model.canRename)
                        .onSubmit { save() }
                        .accessibilityIdentifier("roomRenameField")
                }
                Section("Bots") {
                    ForEach(model.room.members) { member in
                        HStack(spacing: 12) {
                            RoomMemberAvatar(member: member, roster: roster, size: 30)
                            Text(member.displayName)
                            Spacer()
                            Text("@\(member.handle)").font(.footnote).foregroundStyle(PalTokens.textTertiary)
                        }
                    }
                }
            }
            .navigationTitle(Text("Group Chat"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSaveName)
                        .accessibilityIdentifier("roomRenameSave")
                }
            }
        }
        .onAppear { name = model.room.name }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
        .accessibilityIdentifier("roomDetailsSheet")
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
