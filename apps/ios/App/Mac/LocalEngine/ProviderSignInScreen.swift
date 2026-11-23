#if os(macOS)
import PalAuth
import PalBotProfile
import PalDesign
import PalDevice
import SwiftUI

struct ProviderSignInScreen: View {
    let model: ProviderOnboardingModel
    let providerID: String

    @Environment(ServiceSignInCenter.self) private var center
    @State private var pasted = ""
    @State private var clipboardMark: Int?
    @State private var copied = false

    private var service: String { ModelProvidersClient.serviceKey + providerID }

    private var dialog: ServiceSignInDialog? { center.dialog(for: service) }

    private var stage: ProviderSignInStage { .make(dialog: dialog, status: model.providers.status(of: providerID)) }

    private var name: String { model.displayName(providerID) }

    private var promptToken: String? { dialog?.phase == .prompting ? dialog?.requestID : nil }

    var body: some View {
        let stage = stage
        ProviderScreen(
            content: {
                MacOverflowScroll {
                    ProviderColumn { stageContent(stage) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("providerSignIn-\(stage.slug)")
            },
            leading: { },
            trailing: { buttons(stage) }
        )
        .onChange(of: promptToken, initial: true) { _, token in
            if token != nil { Task { await center.signIn(for: service) } }
        }
    }

    @ViewBuilder
    private func stageContent(_ stage: ProviderSignInStage) -> some View {
        switch stage {
        case .starting:
            ProviderHero(providerID: providerID, name: name, headline: String(localized: "Starting sign-in"))
            waiting(String(localized: "Opening the page…"))
        case .browser:
            ProviderHero(
                providerID: providerID, name: name, headline: String(localized: "Finish in your browser"),
                detail: String(localized: "Sign in to \(name) in the page that just opened. Pal continues when you are done."))
            waiting(String(localized: "Waiting for you to finish…"))
        case .code(let code):
            ProviderHero(
                providerID: providerID, name: name, headline: String(localized: "Enter this code"),
                detail: String(localized: "Open the page, then enter this code to sign in to \(name)."))
            codeCard(code)
        case .paste(let note, let submitsAddress):
            ProviderHero(
                providerID: providerID, name: name, headline: String(localized: "Paste the address"),
                detail: submitsAddress ? Self.afterApproving : Self.afterBrowser)
            pasteField(note: note)
        case .finishing:
            ProviderHero(providerID: providerID, name: name, headline: String(localized: "Signed in"))
            waiting(String(localized: "Getting ready to test it…"))
        case .failed(let reason, _, _):
            ProviderHero(
                providerID: providerID, name: name, headline: String(localized: "Sign-in did not finish"), detail: reason,
                detailIsProblem: true)
        }
    }

    private static let afterApproving = String(localized: "After you approve, the page will fail to load. Copy its address and paste it here.")
    private static let afterBrowser = String(
        localized: "When the page says it can't be reached, copy the address from the browser's address bar and paste it here.")

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .hermesText(.botPreview)
        .foregroundStyle(PalTokens.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("providerSignInWaiting")
    }

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: 12) {
            Text(code)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(PalTokens.textPrimary)
                .textSelection(.enabled)
                .accessibilityIdentifier("providerSignInCode")
            Button {
                ServiceSignInClipboard.copy(code)
                copied = true
            } label: {
                Label(copied ? String(localized: "Copied") : String(localized: "Copy code"), palIcon: copied ? "checkmark" : "doc.on.doc")
            }
            .glassButtonStyle()
            .accessibilityIdentifier("providerSignInCopy")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .providerGlass()
        .padding(.top, 20)
    }

    private func pasteField(note: String?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PalGlassTextField(
                    String(localized: "Address"), text: $pasted, prompt: Text("Paste the address here"), isSecure: true,
                    identifier: "providerSignInField")
                Button(action: pasteFromClipboard) {
                    Label("Paste", palIcon: "doc.on.clipboard")
                }
                .glassButtonStyle()
                .accessibilityIdentifier("providerSignInPaste")
            }
            if let note {
                ProviderNote(text: note)
            }
        }
        .padding(.top, 20)
    }

    private func buttons(_ stage: ProviderSignInStage) -> some View {
        HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
            SetupButton(title: String(localized: "Cancel"), kind: .secondary, identifier: "providerSignInCancel", action: cancel)
            switch stage {
            case .starting, .finishing:
                EmptyView()
            case .browser(let canReopen):
                if canReopen { reopenButton(kind: .primary, title: String(localized: "Reopen the page")) }
            case .code:
                reopenButton(kind: .primary, title: String(localized: "Open the page"))
            case .paste(_, let submitsAddress):
                reopenButton(kind: .secondary, title: String(localized: "Reopen the page"))
                SetupButton(title: String(localized: "Continue"), kind: .primary, identifier: "providerSignInContinue") {
                    submit(addressMode: submitsAddress)
                }
                .disabled(PastedCallback(pasted) == nil)
            case .failed(_, let canRetry, let canPasteInstead):
                if canPasteInstead {
                    SetupButton(title: String(localized: "Paste the address instead"), identifier: "providerSignInPasteInstead") {
                        Task { await center.signInByPasting(for: service) }
                    }
                }
                if canRetry { retryButton }
            }
        }
    }

    private func reopenButton(kind: SetupButton.Kind, title: String) -> some View {
        SetupButton(title: title, kind: kind, identifier: "providerSignInReopen", action: reopen)
    }

    private var retryButton: some View {
        SetupButton(title: String(localized: "Try again"), kind: .primary, identifier: "providerSignInRetry") {
            guard let provider = model.providers.provider(id: providerID) else { return }
            Task { await model.retrySignIn(provider) }
        }
    }

    private func cancel() {
        scrubClipboard()
        Task {
            await center.notNow(for: service)
            model.back()
        }
    }

    private func reopen() {
        guard let dialog else { return }
        if case .pasteAddress = dialog.phase {
            center.reopenSignInPage(for: service)
        } else if let uri = dialog.verificationURI, let url = URL(string: uri) {
            ExternalLink.open(url)
        }
    }

    private func pasteFromClipboard() {
        guard let value = ServiceSignInClipboard.paste() else { return }
        clipboardMark = PasteboardScrub(SystemPasteboard()).mark()
        pasted = value
    }

    private func submit(addressMode: Bool) {
        guard let value = PastedCallback(pasted)?.value else { return }
        pasted = ""
        scrubClipboard()
        Task {
            if addressMode {
                await center.submitAddress(value, for: service)
            } else {
                await center.submitCallback(value, for: service)
            }
        }
    }

    private func scrubClipboard() {
        if let mark = clipboardMark { PasteboardScrub(SystemPasteboard()).clear(ifUnchangedSince: mark) }
        clipboardMark = nil
    }
}
#endif
