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

    init(symbol: String, title: String, reason: String, code: String, fault: GatewayFault? = nil) {
        self.symbol = symbol
        self.title = title
        self.reason = reason
        self.code = code
        self.fault = fault
    }
}

struct ChatInstallStatus<Secondary: View>: View {
    let copy: ChatStatusCopy
    let primaryTitle: String?
    let isBusy: Bool
    let perform: () -> Void
    var identifierPrefix = "chatInstall"
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
                    PillButton(primaryTitle, kind: .accent, size: .large, isBusy: isBusy, accessibilityIdentifier: "\(identifierPrefix)Primary") {
                        perform()
                    }
                }
                secondary()
                details
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("\(identifierPrefix)Status")
    }

    private var details: some View {
        DisclosureGroup(String(localized: "Details"), isExpanded: $showsDetails) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.code)
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("\(identifierPrefix)ReasonCode")
                    if let fault = copy.fault {
                        Text(fault.detailsLine)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("\(identifierPrefix)FaultLine")
                    }
                }
                Spacer(minLength: 0)
                Button(String(localized: "Copy")) { Pasteboard.string = copy.details }
                    .buttonStyle(.pill())
                    .accessibilityIdentifier("\(identifierPrefix)CopyDetails")
            }
            .padding(.top, 8)
        }
        .hermesText(.rowSubtitle)
        .foregroundStyle(Color(theme.palette.textSecondary))
        .accessibilityIdentifier("\(identifierPrefix)Details")
    }
}
