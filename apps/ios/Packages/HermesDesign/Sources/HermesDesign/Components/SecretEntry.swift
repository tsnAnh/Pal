import SwiftUI

public enum SecretEntryState: Sendable, Equatable {
    case idle
    case submitting
    case success
    case failure(String)
    case cancelled
    case expired

    public var isTerminal: Bool {
        switch self {
        case .success, .cancelled, .expired: true
        case .idle, .submitting, .failure: false
        }
    }

    public var acceptsInput: Bool {
        switch self {
        case .idle, .failure: true
        case .submitting, .success, .cancelled, .expired: false
        }
    }

    public var requiresEmptyField: Bool {
        isTerminal || self == .submitting
    }

    public var accessibilitySlug: String {
        switch self {
        case .idle: "idle"
        case .submitting: "submitting"
        case .success: "success"
        case .failure: "failure"
        case .cancelled: "cancelled"
        case .expired: "expired"
        }
    }

    public var statusText: String? {
        switch self {
        case .idle: nil
        case .submitting: String(localized: "Saving…")
        case .success: String(localized: "Saved")
        case .failure(let text): text
        case .cancelled: String(localized: "Cancelled")
        case .expired: String(localized: "This request has closed. Ask your bot to try again.")
        }
    }
}

public enum SecretEntryInput {
    public static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public struct SecretEntryIdentifiers: Sendable, Equatable {
    public var field: String
    public var submit: String
    public var cancel: String
    public var status: String

    public init(
        field: String = "secret-entry-field",
        submit: String = "secret-entry-submit",
        cancel: String = "secret-entry-cancel",
        status: String = "secret-entry-status"
    ) {
        self.field = field
        self.submit = submit
        self.cancel = cancel
        self.status = status
    }
}

public struct SecretField: View {
    private let label: String
    private let prompt: String
    private let identifier: String
    private let clearsOnBackground: Bool
    private let clearToken: Int
    @Binding private var text: String

    @Environment(\.scenePhase) private var scenePhase

    public init(
        _ label: String,
        prompt: String? = nil,
        text: Binding<String>,
        identifier: String,
        clearsOnBackground: Bool = true,
        clearToken: Int = 0
    ) {
        self.label = label
        self.prompt = prompt ?? label
        self._text = text
        self.identifier = identifier
        self.clearsOnBackground = clearsOnBackground
        self.clearToken = clearToken
    }

    public var body: some View {
        SecureField(label, text: $text, prompt: Text(prompt))
            .textContentType(nil)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .privacySensitive()
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
            .onChange(of: scenePhase) { _, phase in
                if clearsOnBackground, phase != .active { text = "" }
            }
            .onChange(of: clearToken) { _, _ in text = "" }
    }
}

public struct SecretEntryView: View {
    public let connectorName: String
    public let accountLabel: String
    public let purpose: String
    public let fieldLabel: String
    public let fieldPrompt: String
    public let submitTitle: String
    public let cancelTitle: String
    public let state: SecretEntryState
    public let identifiers: SecretEntryIdentifiers
    public let onSubmit: (String) -> Void
    public let onCancel: () -> Void

    @State private var text = ""

    public init(
        connectorName: String,
        accountLabel: String,
        purpose: String,
        fieldLabel: String = String(localized: "Secret"),
        fieldPrompt: String? = nil,
        submitTitle: String = String(localized: "Save"),
        cancelTitle: String = String(localized: "Not now"),
        state: SecretEntryState,
        identifiers: SecretEntryIdentifiers = SecretEntryIdentifiers(),
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.connectorName = connectorName
        self.accountLabel = accountLabel
        self.purpose = purpose
        self.fieldLabel = fieldLabel
        self.fieldPrompt = fieldPrompt ?? fieldLabel
        self.submitTitle = submitTitle
        self.cancelTitle = cancelTitle
        self.state = state
        self.identifiers = identifiers
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    private var showsField: Bool { state.acceptsInput || state == .submitting }
    private var canSubmit: Bool { state.acceptsInput && SecretEntryInput.trimmed(text) != nil }

    public var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(connectorName)
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .multilineTextAlignment(.center)
                Text(accountLabel)
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(PalTokens.textTertiary)
                    .accessibilityIdentifier("secret-entry-account")
                Text(purpose)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("secret-entry-purpose")
            }
            if showsField {
                SecretField(fieldLabel, prompt: fieldPrompt, text: $text, identifier: identifiers.field)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(!state.acceptsInput)
                    .onSubmit(submit)
            }
            if let status = state.statusText {
                Text(status)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(identifiers.status)
            }
            buttons
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity)
        .background {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("secret-entry-state-\(state.accessibilitySlug)")
        }
        .onChange(of: state) { _, new in
            if new.requiresEmptyField { text = "" }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if showsField {
            VStack(spacing: 8) {
                Button(state == .submitting ? String(localized: "Saving…") : submitTitle, action: submit)
                    .buttonStyle(PillButtonStyle(kind: .accent, size: .large))
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(identifiers.submit)
                Button(cancelTitle, action: cancel)
                    .buttonStyle(PillButtonStyle(kind: .dimmed, size: .large))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(identifiers.cancel)
            }
        } else {
            Button(String(localized: "Close"), action: cancel)
                .buttonStyle(PillButtonStyle(kind: .neutral, size: .large))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(identifiers.cancel)
        }
    }

    private func submit() {
        guard state.acceptsInput, let value = SecretEntryInput.trimmed(text) else { return }
        text = ""
        onSubmit(value)
    }

    private func cancel() {
        text = ""
        onCancel()
    }
}
