import PalConnect
import PalDesign
import SwiftUI

enum UpworkCardText {
    static func summary(_ state: ConnectorCardState, fallback: String) -> String {
        switch state {
        case .failed(let reason): reason
        case .reconnect: String(localized: "Sign in again to keep using Upwork")
        case .connecting: String(localized: "Signing in…")
        case .connect, .connected: fallback
        }
    }

    static func actionTitle(_ state: ConnectorCardState) -> String {
        switch state {
        case .connect, .connecting: String(localized: "Connect")
        case .connected: String(localized: "Manage")
        case .failed: String(localized: "Try again")
        case .reconnect: String(localized: "Reconnect")
        }
    }

    static func status(_ state: ConnectorCardState) -> String {
        switch state {
        case .connect: String(localized: "Not connected")
        case .connecting: String(localized: "Signing in…")
        case .connected: String(localized: "Connected")
        case .failed(let reason): reason
        case .reconnect(let reason): reason ?? String(localized: "Needs you to sign in again")
        }
    }

    static let reads = String(localized: "Your bot can read your Upwork job feed, job details, your proposals and your messages.")
    static let asks = String(localized: "Every action, like sending a message or submitting a proposal, asks you first with a card.")
    static let money = String(localized: "Payments, contracts and other money steps always stay on upwork.com.")
    static let anywhere = String(localized: "Sign in works from any of your devices. Your Pal keeps the sign-in, so every device and bot can use it.")
}

struct UpworkConnectionSheet: View {
    let model: ConnectAppsModel
    let app: ConnectApp

    @Environment(\.dismiss) private var dismiss

    private var current: ConnectApp { model.catalog.apps.first { $0.id == app.id } ?? app }
    private var state: ConnectorCardState { model.cardState(current) }
    private var platform: ConnectorPlatform { ConnectorPlatform.current }
    private var routes: [OAuthSignInRoute] { platform.signInRoutes }

    var body: some View {
        SheetChrome(
            title: current.name,
            accessibilityIdentifier: "upworkConnection",
            leadingAccessibilityIdentifier: "upworkConnectionDone",
            onLeading: { dismiss() },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                        SectionCaption(String(localized: "Status"), accessibilityIdentifier: "upworkStatusCaption")
                        GroupedCard(accessibilityIdentifier: "upworkStatus") {
                            SettingsRow(title: UpworkCardText.status(state), accessibilityIdentifier: "upworkStatusRow")
                        }
                        SectionCaption(String(localized: "What to expect"), accessibilityIdentifier: "upworkExpectCaption")
                        CardFootnote(UpworkCardText.reads, accessibilityIdentifier: "upworkReads")
                        CardFootnote(UpworkCardText.asks, accessibilityIdentifier: "upworkAsks")
                        CardFootnote(UpworkCardText.money, accessibilityIdentifier: "upworkMoney")
                        CardFootnote(UpworkCardText.anywhere, accessibilityIdentifier: "upworkAnywhere")
                        if model.isPastingAddress {
                            pasteEntry
                        } else {
                            actions
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        )
        .onDisappear { Task { await model.cancelPaste() } }
    }

    private var pasteEntry: some View {
        PasteAddressEntry(
            state: model.pasteState,
            identifiers: SecretEntryIdentifiers(
                field: "upwork-paste-field", submit: "upwork-paste-submit", cancel: "upwork-paste-cancel", status: "upwork-paste-status"
            ),
            onSubmit: { value in Task { await model.submitPastedAddress(value) } },
            onReopen: { model.reopenPasteSignIn() },
            onCancel: { Task { await model.cancelPaste() } }
        )
        .padding(.horizontal, 4)
    }

    private func startSignIn() {
        if routes.contains(.automaticReturn) {
            Task { await model.connect(current) }
        } else {
            Task { await model.beginPaste(current) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let title = signInTitle {
            GroupedCard(accessibilityIdentifier: "upworkSignIn") {
                SettingsRow(title: title, accessibilityIdentifier: "upworkSignInRow", action: startSignIn)
                    .disabled(state == .connecting)
            }
        }
        if routes.contains(.automaticReturn), routes.contains(.pasteAddress), offersPasteFallback {
            GroupedCard(accessibilityIdentifier: "upworkPasteInstead") {
                SettingsRow(title: String(localized: "Paste the address instead"), accessibilityIdentifier: "upworkPasteInsteadRow") {
                    Task { await model.beginPaste(current) }
                }
            }
        }
        if current.state != .disconnected {
            GroupedCard(accessibilityIdentifier: "upworkDisconnect") {
                SettingsRow.destructive(String(localized: "Disconnect"), accessibilityIdentifier: "upworkDisconnectRow") {
                    model.disconnectTarget = .app(current)
                    dismiss()
                }
                .disabled(state == .connecting)
            }
        }
    }

    private var offersPasteFallback: Bool {
        if case .failed = state { return true }
        return false
    }

    private var signInTitle: String? {
        switch state {
        case .connect: return String(localized: "Sign in with Upwork")
        case .failed: return String(localized: "Try again")
        case .reconnect: return String(localized: "Reconnect")
        case .connected: return String(localized: "Sign in again")
        case .connecting: return nil
        }
    }
}
