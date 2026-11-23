#if os(macOS)
import PalDesign
import PalLocalEngine
import SwiftUI

struct LocalEngineSettingsSection: View {
    let engine: LocalEngineModel

    @Environment(\.hermesTheme) private var theme
    @State private var confirmingRemoval = false
    @State private var deleteData = MacDialogCheckbox(
        String(localized: "Also delete chats, bots and settings"), identifier: "localEngineDeleteDataCheckbox"
    )

    private var startAtLogin: Binding<Bool> {
        Binding(
            get: { engine.startAtLogin ?? true },
            set: { enabled in Task { await engine.setStartAtLogin(enabled) } }
        )
    }

    private var isRemoving: Bool { engine.state == .removing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacCaption("This Mac")
                .accessibilityIdentifier("localEngineCaption")
            MacCard(identifier: "localEngineCard") {
                MacRow(
                    title: String(localized: "Start at login"),
                    subtitle: String(localized: "Keeps Pal running in the background while you’re logged in."),
                    identifier: "localEngineLoginRow"
                ) {
                    Toggle(String(localized: "Start at login"), isOn: startAtLogin)
                        .labelsHidden()
                        .palSwitch()
                        .disabled(engine.startAtLogin == nil || engine.isUpdatingLogin || isRemoving)
                        .accessibilityIdentifier("localEngineLoginToggle")
                }
                LocalEngineTailnetRows(engine: engine, isRemoving: isRemoving)
                Button {
                    deleteData.isOn = false
                    confirmingRemoval = true
                } label: {
                    MacRow(
                        title: isRemoving ? String(localized: "Removing…") : String(localized: "Remove Pal from this Mac"),
                        identifier: "localEngineRemoveRow"
                    ) { EmptyView() }
                    .foregroundStyle(Color(theme.palette.destructive))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRemoving || engine.isUpdatingLogin || engine.isUpdatingTailnet)
            }
            if let failure = engine.settingsFailure {
                Text(failure.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.top, 8)
                    .accessibilityIdentifier("localEngineSettingsError")
            }
            if let message = engine.tailnetFailure {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.top, 8)
                    .accessibilityIdentifier("localEngineTailnetError")
            }
        }
        .task { await engine.refreshSettings() }
        .onDisappear { engine.dismissTailnetPassword() }
        .macConfirm(isPresented: $confirmingRemoval) {
            MacDialogContent(
                String(localized: "Remove Pal from this Mac?"),
                message: String(
                    localized: "Pal stops and its program files are removed. Your chats, bots and settings stay unless you also choose to delete them."
                ),
                checkbox: deleteData,
                actions: [
                    MacDialogAction(String(localized: "Cancel"), role: .cancel, identifier: "localEngineRemoveCancel"),
                    MacDialogAction(String(localized: "Remove"), role: .destructive, identifier: "localEngineRemoveConfirm") {
                        let deleting = deleteData.isOn
                        Task { await engine.remove(deleteData: deleting) }
                    },
                ]
            )
        }
    }
}
#endif
