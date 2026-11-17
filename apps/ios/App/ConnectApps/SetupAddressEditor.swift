import PalConnect
import PalDesign
import SwiftUI

struct SetupAddressEditor: View {
    let model: SetupGuideModel

    @Environment(\.hermesTheme) private var theme

    private var address: PublicAddressModel { model.address }

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            if address.state == nil {
                if let result = address.result {
                    status(result)
                } else {
                    DelayedProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("setupAddressBusy")
                }
            } else {
                editor
            }
        }
        .task { await address.start() }
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            Text("Your Pal's web page has to be reachable at this https address, for example through Tailscale Serve. Pal can't switch that on for you.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setupAddressNote")
            if let suggestion = address.state?.suggestion, suggestion != address.draft { suggestionCard(suggestion) }
            entry
            VStack(spacing: 10) {
                PillButton(
                    String(localized: "Save"), kind: .accent, size: .large, isBusy: address.isSaving, accessibilityIdentifier: "setupAddressSave"
                ) { Task { await model.saveAddress() } }
                .disabled(!address.canSave)
                PillButton(
                    String(localized: "Check"), size: .large, isBusy: address.isChecking, accessibilityIdentifier: "setupAddressCheck"
                ) { Task { await address.check() } }
                .disabled(!address.canCheck)
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        if let result = address.result { status(result) }
    }

    private func suggestionCard(_ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(String(localized: "Suggested address"), accessibilityIdentifier: "setupAddressSuggestionCaption")
            GroupedCard(accessibilityIdentifier: "setupAddressSuggestionCard") {
                HStack(spacing: 12) {
                    Text(suggestion)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("setupAddressSuggestionValue")
                    Button(String(localized: "Use this")) { address.useSuggestion() }
                        .buttonStyle(.pill())
                        .accessibilityIdentifier("setupAddressUse")
                }
                .padding(.horizontal, PalMetrics.rowInset)
                .padding(.vertical, PalMetrics.rowVerticalPadding)
            }
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(String(localized: "https://pal.example.com"), text: Binding(get: { address.draft }, set: { address.edit($0) }))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .padding(12)
                .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("setupAddressField")
            if let problem = address.problem {
                Text(problem.message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("setupAddressHint")
            } else if case .address = address.verdict {
                Text("Looks right")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("setupAddressOK")
            }
        }
    }

    private func status(_ report: PublicAddressModel.Report) -> some View {
        ChatInstallStatus(
            copy: SetupAddressStatus.copy(report), primaryTitle: address.state == nil ? String(localized: "Try again") : nil, isBusy: false,
            perform: { Task { await address.start() } }, identifierPrefix: "setupAddressResult", secondary: { EmptyView() }
        )
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}

@MainActor
enum SetupAddressStatus {
    static func copy(_ report: PublicAddressModel.Report) -> ChatStatusCopy {
        switch report {
        case .checked(let check): checked(check.outcome)
        case .failed(let error): failed(error)
        }
    }

    private static func checked(_ outcome: PublicAddressOutcome) -> ChatStatusCopy {
        let code = outcome.rawValue.uppercased()
        let warning = "exclamationmark.triangle"
        return switch outcome {
        case .reachable:
            ChatStatusCopy(
                symbol: "checkmark.circle", title: String(localized: "Address reachable"),
                reason: String(localized: "Your Pal answers at this address."), code: code
            )
        case .notReachable:
            ChatStatusCopy(
                symbol: warning, title: String(localized: "Address not reachable"),
                reason: String(localized: "Pal couldn't reach this address. Check that it's online, then check again."), code: code
            )
        case .wrongService:
            ChatStatusCopy(
                symbol: warning, title: String(localized: "Another service answers"),
                reason: String(localized: "Something other than your Pal answers here. The address must reach your Pal over https."), code: code
            )
        case .notServed:
            ChatStatusCopy(
                symbol: warning, title: String(localized: "Address not served yet"),
                reason: String(
                    localized: "Your Pal answers, but not here yet. The address must reach it over https. Restart your Pal after changing the address."
                ),
                code: code
            )
        case .noAddress:
            ChatStatusCopy(symbol: warning, title: String(localized: "No address saved"), reason: String(localized: "Save an address first."), code: code)
        }
    }

    private static func failed(_ error: PublicAddressError) -> ChatStatusCopy {
        let code = error.fault?.reason.uppercased() ?? "UNREACHABLE"
        return switch error.reason {
        case .ownerOnly:
            ChatStatusCopy(
                symbol: "lock", title: String(localized: "Owner only"), reason: String(localized: "Only the owner can change this address."),
                code: code, fault: error.fault
            )
        case .managed:
            ChatStatusCopy(
                symbol: "lock", title: String(localized: "Managed for you"),
                reason: String(localized: "An administrator manages this address, so it can't be changed here."), code: code, fault: error.fault
            )
        case .refused, .other:
            ChatStatusCopy(
                symbol: "exclamationmark.triangle", title: String(localized: "Couldn't reach your Pal"),
                reason: String(localized: "Pal couldn't do that. Try again."), code: code, fault: error.fault
            )
        }
    }
}
