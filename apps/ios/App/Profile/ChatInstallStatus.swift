import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

@MainActor
struct ChatStatusCopy {
    let symbol: String
    let title: String
    let reason: String
    let code: String
    let fault: GatewayFault?

    var details: String {
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]].compactMap { $0 as? String }.joined(separator: " ")
        return "\(fault?.detailsLine ?? "code: \(code)")\napp: \(version)"
    }

    init?(model: ChatInstallModel, displayName: String) {
        guard let code = model.statusCode else { return nil }
        self.code = code
        fault = model.screen == .unavailable ? model.loadFault : nil
        switch model.screen {
        case .unsupported:
            symbol = "arrow.down.circle"
            title = String(localized: "Gateway needs update")
            reason = String(localized: "Update Pal on your computer to set up Slack here.")
        case .error(let error, _):
            symbol = "exclamationmark.bubble"
            title = String(localized: "Setup stopped")
            reason = Self.reason(error, displayName: displayName)
        default:
            let failure = model.loadFailure ?? .gateway
            symbol = failure == .offline || failure == .timedOut ? "wifi.slash" : failure == .forbidden ? "lock" : "exclamationmark.triangle"
            title = String(localized: "Can't reach Slack setup")
            reason = Self.reason(failure)
        }
    }

    private static func reason(_ failure: ChatFailureReason) -> String {
        switch failure {
        case .offline: String(localized: "Pal isn't connected to your computer. Check your connection, then try again.")
        case .timedOut: String(localized: "Your computer took too long to answer. Try again.")
        case .forbidden: String(localized: "This device can't set up Slack. Sign in as the owner, then try again.")
        case .invalidParams: String(localized: "Pal and your computer disagree about this request. Update both, then try again.")
        case .decode: String(localized: "Pal couldn't read your computer's answer. Update Pal, then try again.")
        case .gateway: String(localized: "Your computer couldn't answer. Try again.")
        }
    }

    private static func reason(_ code: ChatSetupErrorCode, displayName: String) -> String {
        switch code {
        case .credentialRejected: String(localized: "Slack didn't accept that setup code. Copy a fresh one and paste it again.")
        case .credentialExpired: String(localized: "The setup code has expired. Copy a new one from Slack.")
        case .appCreateFailed: String(localized: "Pal couldn't create \(displayName)'s Slack app. Try again in a moment.")
        case .allowDenied: String(localized: "Slack didn't get your Allow. Open Slack again and click Allow.")
        case .installFailed: String(localized: "Pal couldn't finish adding \(displayName). Try again in a moment.")
        case .providerUnreachable, .unknown: String(localized: "Pal couldn't reach Slack. Check your connection, then try again.")
        }
    }
}

struct ChatInstallStatus<Secondary: View>: View {
    let copy: ChatStatusCopy
    let primaryTitle: String?
    let isBusy: Bool
    let perform: () -> Void
    @ViewBuilder let secondary: () -> Secondary

    @State private var showsDetails = false
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        ContentUnavailableView {
            Label(copy.title, systemImage: copy.symbol)
        } description: {
            Text(copy.reason)
        } actions: {
            VStack(spacing: 12) {
                if let primaryTitle {
                    PillButton(primaryTitle, kind: .accent, size: .large, isBusy: isBusy, accessibilityIdentifier: "chatInstallPrimary") {
                        perform()
                    }
                }
                secondary()
                details
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("chatInstallStatus")
    }

    private var details: some View {
        DisclosureGroup(String(localized: "Details"), isExpanded: $showsDetails) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.code)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("chatInstallReasonCode")
                    if let fault = copy.fault {
                        Text(fault.detailsLine)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chatInstallFaultLine")
                    }
                }
                Spacer(minLength: 0)
                Button(String(localized: "Copy")) { Pasteboard.string = copy.details }
                    .buttonStyle(.pill())
                    .accessibilityIdentifier("chatInstallCopyDetails")
            }
            .padding(.top, 8)
        }
        .hermesText(.rowSubtitle)
        .foregroundStyle(Color(theme.palette.textSecondary))
        .accessibilityIdentifier("chatInstallDetails")
    }
}
