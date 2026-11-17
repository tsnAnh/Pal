import PalConnect
import PalDesign
import SwiftUI

struct OAuthClientSheet: View {
    let model: OAuthClientSheetModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetChrome(
            title: model.app.name,
            accessibilityIdentifier: "oauthClientSetup",
            leadingAccessibilityIdentifier: "oauthClientCancel",
            onLeading: { dismiss() },
            content: { content }
        )
        .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading, .saving:
            DelayedProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("oauthClientBusy")
        case .form(let setup):
            OAuthClientForm(app: model.app, notes: model.entry.notes, setup: setup) { id, secret in
                Task { await model.save(clientID: id, clientSecret: secret) }
            }
        case .problem(let problem):
            OAuthClientProblemView(problem: problem, name: model.app.name) { Task { await model.retry(problem) } }
        }
    }
}

private struct OAuthClientProblemView: View {
    let problem: OAuthClientProblem
    let name: String
    let retry: () -> Void

    private var genericTitle: String {
        problem.retry == .setup ? String(localized: "Setup stopped") : String(localized: "Couldn't connect \(name)")
    }

    private var copy: ChatStatusCopy {
        switch problem.code {
        case OAuthClientFailure.needsPublicURL.rawValue:
            ChatStatusCopy(symbol: "network", title: String(localized: "Public address needed"), reason: problem.reason, code: problem.code)
        case OAuthClientFailure.notOwner.rawValue:
            ChatStatusCopy(symbol: "lock", title: String(localized: "Owner only"), reason: problem.reason, code: problem.code)
        case OAuthClientFailure.unreachable.rawValue:
            ChatStatusCopy(symbol: "wifi.slash", title: String(localized: "Can't reach your Pal"), reason: problem.reason, code: problem.code)
        default:
            ChatStatusCopy(symbol: "exclamationmark.triangle", title: genericTitle, reason: problem.reason, code: problem.code)
        }
    }

    var body: some View {
        ChatInstallStatus(
            copy: copy, primaryTitle: String(localized: "Try again"), isBusy: false, perform: retry, identifierPrefix: "oauthClient"
        ) { EmptyView() }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}

private struct OAuthClientForm: View {
    let app: ConnectApp
    let notes: String?
    let setup: OAuthClientSetup
    let save: (String, String) -> Void

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var copied = false
    @Environment(\.hermesTheme) private var theme

    private var canSave: Bool { SecretEntryInput.trimmed(clientID) != nil && SecretEntryInput.trimmed(clientSecret) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                steps
                redirect
                fields
                if let notes { CardFootnote(notes, accessibilityIdentifier: "oauthClientNotes") }
                PillButton(String(localized: "Save"), kind: .accent, size: .large, accessibilityIdentifier: "oauthClientSave") {
                    guard let id = SecretEntryInput.trimmed(clientID), let secret = SecretEntryInput.trimmed(clientSecret) else { return }
                    clientID = ""
                    clientSecret = ""
                    save(id, secret)
                }
                .disabled(!canSave)
                .padding(.horizontal, PalMetrics.screenMargin)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(String(localized: "Set up once"), accessibilityIdentifier: "oauthClientStepsCaption")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(OAuthClientGuide.steps(slug: app.oauthClientEntry?.slug ?? "", appName: app.name).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").hermesText(.chip).foregroundStyle(Color(theme.palette.textSecondary))
                        Text(step).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
                    }
                }
            }
            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("oauthClientSteps")
            if let console = setup.consoleURL {
                PillButton(
                    OAuthClientGuide.consoleTitle(slug: app.oauthClientEntry?.slug ?? "", appName: app.name), size: .large,
                    accessibilityIdentifier: "oauthClientConsole"
                ) { ExternalLink.open(console) }
                    .padding(.horizontal, PalMetrics.screenMargin)
            }
        }
    }

    @ViewBuilder
    private var redirect: some View {
        if let address = setup.redirectURL {
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                SectionCaption(String(localized: "Redirect URL"), accessibilityIdentifier: "oauthClientRedirectCaption")
                GroupedCard(accessibilityIdentifier: "oauthClientRedirectCard") {
                    HStack(spacing: 12) {
                        Text(address)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("oauthClientRedirect")
                        Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                            Pasteboard.string = address
                            copied = true
                        }
                        .buttonStyle(.pill())
                        .accessibilityIdentifier("oauthClientCopyRedirect")
                    }
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, PalMetrics.rowVerticalPadding)
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(String(localized: "Your client"), accessibilityIdentifier: "oauthClientFieldsCaption")
            VStack(spacing: 10) {
                field(String(localized: "Client ID"), text: $clientID, identifier: "oauthClientID")
                field(String(localized: "Client secret"), text: $clientSecret, identifier: "oauthClientSecret")
            }
            .padding(.horizontal, PalMetrics.screenMargin)
            CardFootnote(
                String(localized: "Saved once on your Pal for every device. They can't be read back."),
                accessibilityIdentifier: "oauthClientFieldsNote"
            )
        }
    }

    private func field(_ label: String, text: Binding<String>, identifier: String) -> some View {
        SecretField(label, text: text, identifier: identifier)
            .textFieldStyle(.plain)
            .padding(12)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
