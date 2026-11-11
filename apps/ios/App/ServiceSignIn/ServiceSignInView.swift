import HermesDesign
import HermesDevice
import HermesProtocol
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
        switch dialog.reason {
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

    static func keyPrompt(_ dialog: ServiceSignInDialog, botName: (String) -> String) -> String {
        String(localized: "\(botName(dialog.bot)) needs an API key for \(dialog.serviceName) to keep going.")
    }

    static func header(_ dialog: ServiceSignInDialog) -> String {
        String(localized: "Update the \(dialog.serviceName) credential in the connector's settings, then it can carry on.")
    }

    static func status(_ dialog: ServiceSignInDialog) -> String? {
        switch dialog.phase {
        case .prompting: nil
        case .signingIn: dialog.takesKey ? String(localized: "Saving…") : String(localized: "Waiting for you to finish signing in…")
        case .keySet: String(localized: "Key set")
        case .keyFailed(let text): text
        case .signedIn: String(localized: "Signed in")
        case .failed(let text): text
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
}

struct ServiceSignInDialogView: View {
    let center: ServiceSignInCenter
    let botName: (String) -> String
    @State private var copied = false
    @State private var key = ""

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
                .onChange(of: dialog.requestID) { _, _ in
                    copied = false
                    key = ""
                }
        }
    }

    @ViewBuilder
    private func content(_ dialog: ServiceSignInDialog) -> some View {
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
                codeCard(code)
            }
            if dialog.takesKey, dialog.phase != .signedIn, !isFailed(dialog.phase) {
                keyField(dialog)
            }
            if let status = ServiceSignInWording.status(dialog) {
                Text(status)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("service-signin-status")
            }
            buttons(dialog)
        }
    }

    private func subtitle(_ dialog: ServiceSignInDialog) -> String {
        switch dialog.flow {
        case .deviceCode, .oauth: ServiceSignInWording.subtitle(dialog, botName: botName)
        case .apiKey: ServiceSignInWording.keyPrompt(dialog, botName: botName)
        case .header: ServiceSignInWording.header(dialog)
        case .manual, .unknown: ServiceSignInWording.manual(dialog)
        }
    }

    private func isFailed(_ phase: ServiceSignInPhase) -> Bool {
        if case .failed = phase { true } else { false }
    }

    private func keyField(_ dialog: ServiceSignInDialog) -> some View {
        SecureField("API key", text: $key)
            .textContentType(nil)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .textFieldStyle(.plain)
            .padding(12)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!dialog.acceptsKey)
            .onSubmit { saveKey(dialog) }
            .accessibilityIdentifier("service-signin-key-field")
    }

    private func saveKey(_ dialog: ServiceSignInDialog) {
        guard dialog.acceptsKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = key
        key = ""
        Task { await center.saveKey(value) }
    }

    private func showsCode(_ phase: ServiceSignInPhase) -> Bool {
        switch phase {
        case .prompting, .signingIn: true
        case .keySet, .keyFailed, .signedIn, .failed: false
        }
    }

    private func codeCard(_ code: String) -> some View {
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

    @ViewBuilder
    private func buttons(_ dialog: ServiceSignInDialog) -> some View {
        switch dialog.phase {
        case .signedIn:
            EmptyView()
        case .failed:
            Button("Close") { Task { await center.notNow() } }
                .buttonStyle(PillButtonStyle(kind: .neutral, size: .large))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("service-signin-notnow-button")
        case .prompting, .signingIn, .keySet, .keyFailed:
            VStack(spacing: 8) {
                if dialog.takesKey {
                    Button(dialog.phase == .signingIn ? "Saving…" : "Save") { saveKey(dialog) }
                        .buttonStyle(PillButtonStyle(kind: .accent, size: .large))
                        .disabled(!dialog.acceptsKey || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("service-signin-key-save-button")
                } else if dialog.canSignIn {
                    Button(dialog.phase == .signingIn ? "Signing in…" : "Sign in") { Task { await center.signIn() } }
                        .buttonStyle(PillButtonStyle(kind: .accent, size: .large))
                        .disabled(dialog.phase == .signingIn)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("service-signin-signin-button")
                }
                Button(dialog.canSignIn || dialog.takesKey ? "Not now" : "Close") { Task { await center.notNow() } }
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
