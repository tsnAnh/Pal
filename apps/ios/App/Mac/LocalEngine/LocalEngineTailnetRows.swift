#if os(macOS)
import PalDesign
import SwiftUI

struct LocalEngineTailnetRows: View {
    let engine: LocalEngineModel
    let isRemoving: Bool

    private var isOn: Binding<Bool> {
        Binding(
            get: { engine.tailnet != nil && engine.tailnet != .off },
            set: { enabled in
                Task { if enabled { await engine.enableTailnet() } else { await engine.disableTailnet() } }
            }
        )
    }

    var body: some View {
        MacRow(
            title: String(localized: "Reach from iPhone"),
            subtitle: String(localized: "Use Pal from your iPhone over Tailscale."),
            identifier: "localEngineTailnetRow"
        ) {
            Toggle(String(localized: "Reach from iPhone"), isOn: isOn)
                .labelsHidden()
                .palSwitch()
                .disabled(engine.isUpdatingTailnet || isRemoving)
                .accessibilityIdentifier("localEngineTailnetToggle")
        }
        if case .on(let url, let username, let reachable) = engine.tailnet {
            copyRow(
                title: String(localized: "Address"), value: url, identifier: "localEngineTailnetURL", copyIdentifier: "localEngineTailnetCopy"
            )
            copyRow(
                title: String(localized: "Username"), value: username, identifier: "localEngineTailnetUsername",
                copyIdentifier: "localEngineTailnetUsernameCopy"
            )
            if let password = engine.tailnetPassword {
                MacRow(
                    title: String(localized: "Password"),
                    subtitle: password,
                    identifier: "localEngineTailnetPassword"
                ) {
                    HStack(spacing: 8) {
                        Button(String(localized: "Copy")) { Pasteboard.string = password }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("localEngineTailnetPasswordCopy")
                        Button(String(localized: "Done")) { engine.dismissTailnetPassword() }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("localEngineTailnetPasswordDone")
                    }
                }
                MacFootnote(
                    text: String(localized: "Save this password now. Pal won’t show it again."), identifier: "localEngineTailnetPasswordNote"
                )
                .padding(.bottom, 8)
            } else {
                Button {
                    Task { await engine.enableTailnet() }
                } label: {
                    MacRow(title: String(localized: "Create a new password"), identifier: "localEngineTailnetNewPasswordRow") { EmptyView() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(engine.isUpdatingTailnet || isRemoving)
                .accessibilityIdentifier("localEngineTailnetNewPassword")
            }
            if reachable == false {
                MacFootnote(text: String(localized: "Pal is on, but your iPhone can’t reach it yet."), identifier: "localEngineTailnetUnreachable")
                    .padding(.bottom, 8)
            }
        }
    }

    private func copyRow(title: String, value: String, identifier: String, copyIdentifier: String) -> some View {
        MacRow(title: title, subtitle: value, identifier: identifier) {
            Button(String(localized: "Copy")) { Pasteboard.string = value }
                .buttonStyle(.glass)
                .accessibilityIdentifier(copyIdentifier)
        }
    }
}
#endif
