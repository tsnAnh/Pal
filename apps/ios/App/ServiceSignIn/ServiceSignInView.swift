import PalDesign
import PalDevice
import PalProtocol
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ServiceSignInWording {
    static func title(_ dialog: ServiceSignInDialog) -> String {
        String(localized: "Sign in to \(dialog.serviceName)")
    }

    static func subtitle(_ dialog: ServiceSignInDialog, botName: (String) -> String) -> String {
        let name = botName(dialog.bot)
        return switch dialog.reason {
        case .expired: String(localized: "\(name) needs you to sign in to \(dialog.serviceName) again. Your last sign-in has expired.")
        case .revoked: String(localized: "\(name) lost access to \(dialog.serviceName). Sign in again to give it back.")
        case .missing, .unknown: String(localized: "\(name) needs you to sign in to \(dialog.serviceName) to keep going.")
        }
    }

    static func others(_ dialog: ServiceSignInDialog) -> String? {
        let count = dialog.otherBotCount
        guard count > 0 else { return nil }
        return count == 1 ? String(localized: "+1 other bot is waiting too.") : String(localized: "+\(count) other bots are waiting too.")
    }

    static func manual(_ dialog: ServiceSignInDialog) -> String {
        String(localized: "Sign in to \(dialog.serviceName) on the computer your bot runs on, then it can carry on.")
    }

    static let anyDevice = String(localized: "Sign in works from any of your devices. Your Pal keeps the sign-in, so every device and bot can use it.")

    static func keyPrompt(_ dialog: ServiceSignInDialog, botName: (String) -> String) -> String {
        String(localized: "\(botName(dialog.bot)) needs a credential for \(dialog.serviceName) to keep going.")
    }

    static func purpose(_ dialog: ServiceSignInDialog, botName: (String) -> String) -> String {
        String(localized: "Used by \(botName(dialog.bot)) to call \(dialog.serviceName)")
    }

    static func account(_ dialog: ServiceSignInDialog, botName: (String) -> String) -> String {
        String(localized: "Bot: \(botName(dialog.bot))")
    }

    static func fieldLabel(_ dialog: ServiceSignInDialog) -> String {
        dialog.flow == .apiKey ? String(localized: "API key") : String(localized: "Credential")
    }

    static func entryState(_ phase: ServiceSignInPhase) -> SecretEntryState {
        switch phase {
        case .prompting: .idle
        case .signingIn: .submitting
        case .pasteAddress(let note): note.map(SecretEntryState.failure) ?? .idle
        case .keySet, .signedIn: .success
        case .keyFailed(let text), .callbackFailed(let text), .failed(let text): .failure(text)
        case .expired: .expired
        }
    }

    static func status(_ dialog: ServiceSignInDialog) -> String? {
        switch dialog.phase {
        case .prompting: nil
        case .signingIn: String(localized: "Waiting for you to finish signing in…")
        case .pasteAddress(let note): note
        case .keySet: String(localized: "Key set")
        case .keyFailed(let text), .callbackFailed(let text): text
        case .signedIn: String(localized: "Signed in")
        case .failed(let text): text
        case .expired: SecretEntryState.expired.statusText
        }
    }
}

enum ServiceSignInClipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    @MainActor
    static func paste() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #elseif os(macOS)
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

struct ServiceSignInPasteStep: View {
    let onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 10) {
            Text("Finish in your browser. When the page says it can't be reached, copy the address from the browser's address bar and paste it here.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
            TextField("Address from the browser", text: $text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textPrimary)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .padding(12)
                .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("service-signin-callback-field")
            HStack(spacing: 8) {
                Button {
                    if let pasted = ServiceSignInClipboard.paste() { text = pasted }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                .accessibilityIdentifier("service-signin-callback-paste-button")
                Button("Continue") {
                    onSubmit(text)
                    text = ""
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(PastedCallback(text) == nil)
                .accessibilityIdentifier("service-signin-callback-submit-button")
            }
        }
    }
}

struct ServiceSignInCodeCard: View {
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            Text(code)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(PalTokens.textPrimary)
                .textSelection(.enabled)
                .accessibilityIdentifier("service-signin-code")
            Button {
                ServiceSignInClipboard.copy(code)
                copied = true
            } label: {
                Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(PillButtonStyle(kind: .neutral))
            .accessibilityIdentifier("service-signin-copy-button")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ServiceSignInDialogView: View {
    let center: ServiceSignInCenter
    let botName: (String) -> String
    var body: some View {
        if let dialog = center.current {
            content(dialog)
                .frame(maxWidth: .infinity)
                .padding(24)
                #if os(macOS)
                .frame(width: 400)
                #endif
                .background(PalTokens.elevated)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("service-signin-dialog")
        }
    }

    private func usesSecretEntry(_ dialog: ServiceSignInDialog) -> Bool {
        guard dialog.takesKey else { return false }
        return switch dialog.phase {
        case .prompting, .signingIn, .keySet, .keyFailed, .expired: true
        case .pasteAddress, .callbackFailed, .signedIn, .failed: false
        }
    }

    private func keyEntry(_ dialog: ServiceSignInDialog) -> some View {
        VStack(spacing: 16) {
            SecretEntryView(
                connectorName: dialog.serviceName,
                accountLabel: ServiceSignInWording.account(dialog, botName: botName),
                purpose: ServiceSignInWording.purpose(dialog, botName: botName),
                fieldLabel: ServiceSignInWording.fieldLabel(dialog),
                state: ServiceSignInWording.entryState(dialog.phase),
                identifiers: SecretEntryIdentifiers(
                    field: "service-signin-key-field",
                    submit: "service-signin-key-save-button",
                    cancel: "service-signin-notnow-button",
                    status: "service-signin-status"
                ),
                onSubmit: { value in Task { await center.submitCredential(SecretString(value)) } },
                onCancel: { Task { await center.notNow() } }
            )
            .id(dialog.requestID)
            if let others = ServiceSignInWording.others(dialog) {
                Text(others)
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(PalTokens.textTertiary)
            }
        }
    }

    private func pasteEntry(_ dialog: ServiceSignInDialog) -> some View {
        PasteAddressEntry(
            state: ServiceSignInWording.entryState(dialog.phase),
            identifiers: SecretEntryIdentifiers(
                field: "service-signin-paste-field", submit: "service-signin-paste-submit",
                cancel: "service-signin-notnow-button", status: "service-signin-status"
            ),
            onSubmit: { value in Task { await center.submitAddress(value) } },
            onReopen: { center.reopenSignInPage() },
            onCancel: { Task { await center.notNow() } }
        )
        .id(dialog.requestID)
    }

    @ViewBuilder
    private func content(_ dialog: ServiceSignInDialog) -> some View {
        if case .pasteAddress = dialog.phase {
            pasteEntry(dialog)
        } else if usesSecretEntry(dialog) {
            keyEntry(dialog)
        } else {
            standardContent(dialog)
        }
    }

    @ViewBuilder
    private func standardContent(_ dialog: ServiceSignInDialog) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(ServiceSignInWording.title(dialog))
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .multilineTextAlignment(.center)
                if dialog.phase != .signedIn {
                    Text(subtitle(dialog))
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textSecondary)
                        .multilineTextAlignment(.center)
                    if let others = ServiceSignInWording.others(dialog) {
                        Text(others)
                            .hermesText(.footnoteCaption)
                            .foregroundStyle(PalTokens.textTertiary)
                    }
                }
            }
            if dialog.flow == .deviceCode, let code = dialog.userCode, showsCode(dialog.phase) {
                ServiceSignInCodeCard(code: code).id(code)
            }
            if let status = ServiceSignInWording.status(dialog) {
                Text(status)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("service-signin-status")
            }
            if dialog.requiresAppSignIn, dialog.phase == .prompting {
                Text(ServiceSignInWording.anyDevice)
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(PalTokens.textTertiary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("service-signin-anydevice")
            }
            if dialog.flow == .oauthPaste, awaitsCallback(dialog.phase) {
                ServiceSignInPasteStep { text in Task { await center.submitCallback(text) } }
            }
            buttons(dialog)
        }
    }

    private func awaitsCallback(_ phase: ServiceSignInPhase) -> Bool {
        switch phase {
        case .signingIn, .callbackFailed: true
        case .prompting, .pasteAddress, .keySet, .keyFailed, .signedIn, .failed, .expired: false
        }
    }

    private func subtitle(_ dialog: ServiceSignInDialog) -> String {
        if dialog.requiresAppSignIn { return ServiceSignInWording.subtitle(dialog, botName: botName) }
        switch dialog.flow {
        case .deviceCode, .oauth, .oauthPaste: return ServiceSignInWording.subtitle(dialog, botName: botName)
        case .apiKey, .header: return ServiceSignInWording.keyPrompt(dialog, botName: botName)
        case .manual, .unknown: return ServiceSignInWording.manual(dialog)
        }
    }

    private func showsCode(_ phase: ServiceSignInPhase) -> Bool {
        switch phase {
        case .prompting, .signingIn: true
        case .pasteAddress, .keySet, .keyFailed, .callbackFailed, .signedIn, .failed, .expired: false
        }
    }

    @ViewBuilder
    private func buttons(_ dialog: ServiceSignInDialog) -> some View {
        switch dialog.phase {
        case .signedIn:
            EmptyView()
        case .failed, .expired:
            if dialog.canPasteInstead {
                Button("Paste the address instead") { Task { await center.signInByPasting() } }
                    .buttonStyle(PillButtonStyle(kind: .accent, size: .large))
                    .accessibilityIdentifier("service-signin-paste-instead-button")
            }
            Button("Close") { Task { await center.notNow() } }
                .buttonStyle(PillButtonStyle(kind: .neutral, size: .large))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("service-signin-notnow-button")
        case .prompting, .signingIn, .pasteAddress, .keySet, .keyFailed, .callbackFailed:
            VStack(spacing: 8) {
                if dialog.canSignIn {
                    Button(dialog.phase == .prompting ? "Sign in" : "Signing in…") { Task { await center.signIn() } }
                        .buttonStyle(PillButtonStyle(kind: .accent, size: .large))
                        .disabled(dialog.phase != .prompting)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("service-signin-signin-button")
                }
                Button(dialog.canSignIn ? "Not now" : "Close") { Task { await center.notNow() } }
                    .buttonStyle(PillButtonStyle(kind: .dimmed, size: .large))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("service-signin-notnow-button")
            }
        }
    }
}

private struct ServiceSignInPresentation: ViewModifier {
    let center: ServiceSignInCenter
    let botName: (String) -> String

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { center.current != nil }, set: { _ in })) {
            ServiceSignInDialogView(center: center, botName: botName)
                .interactiveDismissDisabled()
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
    }
}

extension View {
    func serviceSignInDialog(_ center: ServiceSignInCenter, botName: @escaping (String) -> String) -> some View {
        modifier(ServiceSignInPresentation(center: center, botName: botName))
    }
}
