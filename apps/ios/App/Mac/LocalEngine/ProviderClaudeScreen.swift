#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct ProviderClaudeScreen: View {
    static let defaultDisclosure = String(
        localized: "Every turn counts against your Claude plan allowance, and uses whichever account Claude Code is signed in to.")

    let model: ProviderOnboardingModel
    let providerID: String

    private var name: String { model.displayName(providerID) }

    var body: some View {
        ProviderScreen(
            content: {
                MacOverflowScroll {
                    ProviderColumn { stateContent }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("providerClaude")
            },
            leading: {
                SetupQuietButton(title: String(localized: "Skip for now"), identifier: "localEngineProvidersSkip") {
                    Task { await model.skip() }
                }
                .disabled(model.isFinishing || model.hostCheck == .installing)
            },
            trailing: { footerButtons }
        )
        .task(id: providerID) { await model.checkHost(providerID) }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.hostCheck {
        case .idle, .checking:
            hero(String(localized: "Checking Claude Code…"), detail: nil)
            ProgressView()
                .controlSize(.small)
                .padding(.top, 18)
                .accessibilityIdentifier("providerClaudeChecking")
        case .failed(let reason):
            hero(String(localized: "Could not check Claude Code"), detail: reason, problem: true)
        case .installing:
            hero(String(localized: "Installing the Claude plugin"), detail: nil)
            ProgressView()
                .controlSize(.small)
                .padding(.top, 18)
                .accessibilityIdentifier("providerClaudeInstalling")
        case .installFailed(let reason):
            hero(String(localized: "Could not install the plugin"), detail: reason, problem: true)
        case .checked(let check):
            checkedContent(check)
        }
    }

    @ViewBuilder
    private func checkedContent(_ check: ProviderHostCheck) -> some View {
        switch check.stage {
        case .cliMissing:
            hero(String(localized: "Claude Code was not found"), detail: nil)
            steps(check)
            hint(check.installHint ?? String(localized: "Install Claude Code, run claude once to sign in, then check again."))
        case .notSignedIn:
            hero(String(localized: "Sign in to Claude Code"), detail: nil)
            steps(check)
            hint(String(localized: "Run claude once to sign in, then check again."))
        case .pluginMissing:
            hero(String(localized: "Install the Claude plugin"), detail: nil)
            steps(check)
            hint(String(localized: "Pal needs a small plugin to talk to Claude Code. Installing it changes nothing else on this Mac."))
        case .ready:
            hero(String(localized: "Claude is ready"), detail: nil)
            steps(check)
            hint(check.disclosure ?? Self.defaultDisclosure, identifier: "providerClaudeDisclosure")
        }
    }

    private func hero(_ headline: String, detail: String?, problem: Bool = false) -> some View {
        ProviderHero(providerID: providerID, name: name, headline: headline, detail: detail, detailIsProblem: problem)
    }

    private func steps(_ check: ProviderHostCheck) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stepRow(done: check.cliFound, title: foundTitle(check))
            if check.cliFound {
                stepRow(done: check.signedIn, title: signedInTitle(check))
            }
            if check.cliFound, check.signedIn {
                stepRow(
                    done: check.pluginInstalled,
                    title: check.pluginInstalled ? String(localized: "Claude plugin installed") : String(localized: "Claude plugin not installed"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .providerGlass()
        .padding(.top, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providerClaudeSteps")
    }

    private func foundTitle(_ check: ProviderHostCheck) -> String {
        guard check.cliFound else { return String(localized: "Claude Code is not installed on this Mac") }
        guard let version = check.cliVersion else { return String(localized: "Claude Code found") }
        return String(localized: "Claude Code found (\(version))")
    }

    private func signedInTitle(_ check: ProviderHostCheck) -> String {
        guard check.signedIn else { return String(localized: "Not signed in to Claude Code") }
        guard let plan = check.plan else { return String(localized: "Signed in to Claude Code") }
        return String(localized: "Signed in with a Claude \(plan) plan")
    }

    private func stepRow(done: Bool, title: String) -> some View {
        HStack(spacing: 10) {
            PalIcon(done ? "checkmark.circle.fill" : "xmark.circle.fill", ink: done ? .success : .destructive)
            Text(title)
                .hermesText(.rowTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func hint(_ text: String, identifier: String = "providerClaudeHint") -> some View {
        Text(text)
            .hermesText(.botPreview)
            .foregroundStyle(PalTokens.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch model.hostCheck {
        case .idle, .checking:
            SetupButton(title: String(localized: "Check again"), kind: .primary, isBusy: true, identifier: "providerClaudeCheckAgain") {}
        case .installing:
            installButton(title: String(localized: "Installing"), busy: true)
        case .failed:
            checkAgain
        case .installFailed:
            installButton(title: String(localized: "Try again"))
        case .checked(let check):
            checkedButtons(check.stage)
        }
    }

    @ViewBuilder
    private func checkedButtons(_ stage: ProviderHostCheck.Stage) -> some View {
        switch stage {
        case .cliMissing, .notSignedIn: checkAgain
        case .pluginMissing: installButton(title: String(localized: "Install the Claude plugin"))
        case .ready:
            SetupButton(title: String(localized: "Continue"), kind: .primary, identifier: "providerClaudeContinue") {
                Task { await model.continueWithClaude(providerID) }
            }
            .disabled(model.isFinishing)
        }
    }

    private var checkAgain: some View {
        SetupButton(title: String(localized: "Check again"), kind: .primary, identifier: "providerClaudeCheckAgain") {
            Task { await model.checkHost(providerID) }
        }
    }

    private func installButton(title: String, busy: Bool = false) -> some View {
        SetupButton(title: title, kind: .primary, isBusy: busy, identifier: "providerClaudeInstall") {
            Task { await model.installPlugin(providerID) }
        }
    }
}
#endif
