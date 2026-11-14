#if os(macOS)
import PalDesign
import PalT3Code
import SwiftUI

struct MacT3CodeRow: View {
    let host: T3CodeHost
    let confirmDisconnect: () -> Void

    private var controller: T3CodeController { host.controller }

    var body: some View {
        let look = T3CodeRowPresentation(controller.connection)
        HStack(spacing: 8) {
            AppTile(style: .filled(RGB(hex: 0x1f2430))) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(0.95)
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "T3 Code"))
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                Text(String(localized: String.LocalizationValue(look.summary)))
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("deviceConnector-t3code-summary")
            }
            Spacer(minLength: 8)
            if look.isBusy {
                ProgressView().controlSize(.small)
            } else if let title = look.buttonTitle, let action = look.action {
                MacRowAction(title: String(localized: String.LocalizationValue(title)), prominent: action != .disconnect) { perform(action) }
                    .view(identifier: "deviceConnector-t3code-action")
            }
        }
        .frame(height: 60.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceConnector-t3code")
    }

    private func perform(_ action: T3CodeRowPresentation.Action) {
        switch action {
        case .openApp: host.openApplication()
        case .connect: Task { await controller.connect() }
        case .disconnect: confirmDisconnect()
        }
    }
}
#endif
