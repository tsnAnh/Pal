import PalAuth
import PalConnect
import PalDesign
import SwiftUI

struct PasteAddressEntry: View {
    let state: SecretEntryState
    let identifiers: SecretEntryIdentifiers
    let onSubmit: (String) -> Void
    let onReopen: () -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var clipboardMark: Int?

    private var canSubmit: Bool { state.acceptsInput && SecretEntryInput.trimmed(text) != nil }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Paste the address")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .multilineTextAlignment(.center)
                Text("After you approve, the page will fail to load. Copy its address and paste it here.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paste-address-instructions")
                if !ConnectorPlatform.current.returnsAutomatically {
                    Text("Automatic return isn't available on this device, so this one step is manual.")
                        .hermesText(.footnoteCaption)
                        .foregroundStyle(PalTokens.textTertiary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("paste-address-manual-note")
                }
            }
            SecretField(String(localized: "Address"), prompt: String(localized: "Paste the address here"), text: $text, identifier: identifiers.field)
                .textFieldStyle(.plain)
                .padding(12)
                .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(!state.acceptsInput)
                .onSubmit(submit)
                .onChange(of: text) { old, new in
                    if old.isEmpty, new.count > 8 { clipboardMark = PasteboardScrub(SystemPasteboard()).mark() }
                }
            if let status = statusText {
                Text(status)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(identifiers.status)
            }
            VStack(spacing: 8) {
                Button(state == .submitting ? String(localized: "Signing in…") : String(localized: "Finish sign-in"), action: submit)
                    .buttonStyle(PillButtonStyle(kind: .accent, size: .large))
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(identifiers.submit)
                Button(String(localized: "Open the sign-in page again"), action: onReopen)
                    .buttonStyle(PillButtonStyle(kind: .neutral, size: .large))
                    .disabled(state == .submitting)
                    .accessibilityIdentifier("paste-address-reopen")
                Button(String(localized: "Cancel"), action: cancel)
                    .buttonStyle(PillButtonStyle(kind: .dimmed, size: .large))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(identifiers.cancel)
            }
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity)
        .onChange(of: state) { _, new in
            if new.requiresEmptyField { text = "" }
        }
    }

    private var statusText: String? {
        if state == .submitting { return String(localized: "Finishing the sign-in…") }
        return state.statusText
    }

    private func submit() {
        guard state.acceptsInput, let value = SecretEntryInput.trimmed(text) else { return }
        text = ""
        scrubClipboard()
        onSubmit(value)
    }

    private func cancel() {
        text = ""
        scrubClipboard()
        onCancel()
    }

    private func scrubClipboard() {
        if let mark = clipboardMark { PasteboardScrub(SystemPasteboard()).clear(ifUnchangedSince: mark) }
        clipboardMark = nil
    }
}
