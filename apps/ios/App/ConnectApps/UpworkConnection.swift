import PalConnect
import PalDesign
import SwiftUI

enum UpworkCardText {
    static func summary(_ state: ConnectorCardState, fallback: String) -> String {
        switch state {
        case .failed(let reason): reason
        case .signInOnMac(let reason): reason == nil ? String(localized: "Sign in on your Mac") : String(localized: "Sign in again on a Mac")
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
        case .signInOnMac: String(localized: "Details")
        }
    }

    static func status(_ state: ConnectorCardState) -> String {
        switch state {
        case .connect: String(localized: "Not connected")
        case .connecting: String(localized: "Signing in…")
        case .connected: String(localized: "Connected")
        case .failed(let reason): reason
        case .reconnect(let reason): reason ?? String(localized: "Needs you to sign in again")
        case .signInOnMac(let reason): reason ?? String(localized: "Sign in on your Mac")
        }
    }

    static let reads = String(localized: "Your bot can read your Upwork job feed, job details, your proposals and your messages.")
    static let asks = String(localized: "Every action, like sending a message or submitting a proposal, asks you first with a card.")
    static let money = String(localized: "Payments, contracts and other money steps always stay on upwork.com.")
    static let iPhone = String(localized: "Signing in happens on your Mac. Once it is done there, Upwork shows as connected here.")
}

struct UpworkConnectionSheet: View {
    let model: ConnectAppsModel
    let app: ConnectApp

    @Environment(\.dismiss) private var dismiss

    private var current: ConnectApp { model.catalog.apps.first { $0.id == app.id } ?? app }
    private var state: ConnectorCardState { model.cardState(current) }
    private var signsInHere: Bool { ConnectorPlatform.current == .mac }

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
                        if !signsInHere { CardFootnote(UpworkCardText.iPhone, accessibilityIdentifier: "upworkOnMac") }
                        actions
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        )
    }

    @ViewBuilder
    private var actions: some View {
        if signsInHere, let title = signInTitle {
            GroupedCard(accessibilityIdentifier: "upworkSignIn") {
                SettingsRow(title: title, accessibilityIdentifier: "upworkSignInRow") {
                    Task { await model.connect(current) }
                }
                .disabled(state == .connecting)
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

    private var signInTitle: String? {
        switch state {
        case .connect: String(localized: "Sign in with Upwork")
        case .failed: String(localized: "Try again")
        case .reconnect, .connected: String(localized: "Sign in again")
        case .connecting, .signInOnMac: nil
        }
    }
}
