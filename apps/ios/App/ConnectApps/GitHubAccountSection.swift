import PalBotProfile
import PalDesign
import PalDevice
import SwiftUI

struct GitHubAccountSection: View {
    let model: GitHubAccountModel

    @Environment(ServiceSignInCenter.self) private var signInCenter

    private var status: GitHubStatus? {
        if case .ready(let status) = model.phase { status } else { nil }
    }

    private var accountText: String {
        switch model.phase {
        case .loading: "Checking…"
        case .unsupported: "Not available"
        case .unavailable: "Unknown"
        case .ready(let status): status.accountLine
        }
    }

    private var footnote: String? {
        switch model.phase {
        case .unsupported: "This gateway does not support GitHub sign-in yet."
        case .unavailable: "Couldn't check GitHub. Refresh to try again."
        case .loading, .ready: fixFootnote
        }
    }

    private var fixFootnote: String? {
        switch model.fix {
        case .saved: "Saved."
        case .failed: "Couldn't save that. Try again."
        case .idle, .working: nil
        }
    }

    private var offersSignIn: Bool {
        status?.signedIn == false && !model.problems.contains { $0.fix == .signIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption("GitHub", accessibilityIdentifier: "githubCaption")
            GroupedCard(accessibilityIdentifier: "githubAccountCard") {
                SettingsRow.value(
                    "GitHub", value: accountText, subtitle: status?.gitProtocol.label, accessibilityIdentifier: "githubAccountRow")
                ForEach(model.problems) { problemRows($0) }
                if offersSignIn {
                    actionRow(.signIn)
                }
                SettingsRow(
                    title: "Refresh", trailing: .none, accessibilityIdentifier: "githubRefreshRow",
                    action: { Task { await model.refresh() } })
            }
            if let footnote {
                CardFootnote(footnote, accessibilityIdentifier: "githubFootnote")
            }
        }
        .task { await model.refresh() }
        .onChange(of: signInCenter.lastResolution) { _, resolution in
            if resolution?.service == "github" { Task { await model.refresh() } }
        }
        .sheet(isPresented: Binding(get: { model.signIn != nil }, set: { if !$0 { Task { await model.closeSignIn() } } })) {
            GitHubSignInSheet(model: model)
        }
    }

    @ViewBuilder
    private func problemRows(_ problem: GitHubProblem) -> some View {
        Text(problem.message)
            .hermesText(.rowSubtitle)
            .foregroundStyle(PalTokens.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PalMetrics.rowInset)
            .padding(.vertical, 8)
            .accessibilityIdentifier("githubProblem-\(problem.id)")
        if let fix = problem.fix {
            actionRow(fix)
        }
    }

    private func actionRow(_ fix: GitHubFix) -> some View {
        SettingsRow(
            title: model.fix == .working && fix == .gitProtocol ? "Switching…" : fix.actionTitle,
            trailing: .none,
            accessibilityIdentifier: "githubFix-\(fix == .signIn ? "signin" : "protocol")",
            action: { Task { await model.perform(fix) } }
        )
        .disabled(model.fix == .working)
    }
}

struct GitHubSignInSheet: View {
    let model: GitHubAccountModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to GitHub")
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
            content
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        #if os(macOS)
        .frame(width: 400)
        #endif
        .background(PalTokens.elevated)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github-signin-sheet")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.signIn {
        case .starting, nil:
            ProgressView().accessibilityIdentifier("github-signin-starting")
        case .code(let code):
            codeContent(code)
        case .signedIn(let login):
            message(login.map { "Signed in as \($0)." } ?? "Signed in.")
            button("Done", kind: .accent, id: "github-signin-done")
        case .expired:
            message("That code expired.")
            retryButtons
        case .failed(let text):
            message(text)
            retryButtons
        }
    }

    private func codeContent(_ code: GitHubSignInCode) -> some View {
        VStack(spacing: 16) {
            message("Open GitHub and enter this code to finish signing in.")
            ServiceSignInCodeCard(code: code.userCode).id(code.sessionID)
            PillButton("Open GitHub", kind: .accent, size: .large, accessibilityIdentifier: "github-signin-open") {
                ExternalLink.open(code.verificationURL)
            }
            message("Waiting for you to finish signing in…")
            button("Cancel", kind: .dimmed, id: "github-signin-cancel")
        }
    }

    private var retryButtons: some View {
        VStack(spacing: 8) {
            PillButton("Try again", kind: .accent, size: .large, accessibilityIdentifier: "github-signin-retry") {
                Task { await model.beginSignIn() }
            }
            button("Close", kind: .dimmed, id: "github-signin-close")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(PalTokens.textSecondary)
            .multilineTextAlignment(.center)
    }

    private func button(_ title: String, kind: PillKind, id: String) -> some View {
        PillButton(title, kind: kind, size: .large, accessibilityIdentifier: id) { Task { await model.closeSignIn() } }
    }
}
