import PalDesign
import PalDevice
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct MacMessagesConnectorRow: View {
    let model: MessagesConnectorModel

    var body: some View {
        let row = model.row
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "message")
                .font(.system(size: 16))
                .foregroundStyle(row.isOn ? PalTokens.toggleOn : PalTokens.textTertiary)
                .frame(width: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 12))
                        .foregroundStyle(PalTokens.textPrimary)
                    Spacer(minLength: 8)
                    Toggle(row.title, isOn: Binding(get: { model.row.isOn }, set: { on in Task { await model.setOn(on) } }))
                        .labelsHidden()
                        .toggleStyle(.macSwitch)
                        .accessibilityIdentifier("messagesConnectorToggle")
                }
                Text(row.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = row.status {
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PalTokens.textSecondary)
                        .accessibilityIdentifier("messagesConnectorStatus")
                }
                if row.action == .openFullDiskAccess {
                    Button(MessagesConnectorRow.openSettingsTitle) { model.openFullDiskAccess() }
                        .buttonStyle(.palPill(height: 22, fontSize: 11, fill: nil))
                        .padding(.top, 2)
                        .accessibilityIdentifier("messagesConnectorOpenSettings")
                }
                if model.changeFailed {
                    Text("Couldn't change this. Try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messagesConnectorRow")
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshAccess() }
        }
    }
}
#else
struct PhoneMessagesConnectorRow: View {
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let row = MessagesConnectorRow.make(host: .phone, state: nil, access: nil)
        HStack(alignment: .top, spacing: ConnectRowMetrics.tileToTextGap) {
            Image(systemName: "message")
                .font(.system(size: 20))
                .foregroundStyle(Color(theme.palette.textTertiary))
                .frame(width: ConnectRowMetrics.tileSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: ConnectRowMetrics.titleSize))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                Text(row.subtitle)
                    .font(.system(size: ConnectRowMetrics.subtitleSize))
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
        .padding(.vertical, ConnectRowMetrics.verticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messagesConnectorRow")
    }
}
#endif
