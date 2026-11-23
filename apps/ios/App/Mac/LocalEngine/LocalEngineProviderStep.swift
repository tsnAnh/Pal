#if os(macOS)
import PalBotProfile
import PalDesign
import PalDevice
import PalProtocol
import SwiftUI

struct LocalEngineProviderStep: View {
    let engine: LocalEngineModel
    let model: ModelProvidersModel

    @Environment(ServiceSignInCenter.self) private var signIn
    @State private var showsAll = false

    var body: some View {
        PanelColumn {
            VStack(spacing: 0) {
                header
                content
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        } action: {
            VStack(spacing: 6) {
                PanelButton(title: String(localized: "Continue"), kind: .primary, identifier: "localEngineProvidersContinue") {
                    engine.finishProviderStep()
                }
                .disabled(!model.hasConnectedProvider || model.isSigningInAny)
                Button("Skip for now") { engine.finishProviderStep() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(height: 32)
                    .disabled(model.isSigningInAny)
                    .accessibilityIdentifier("localEngineProvidersSkip")
            }
            .padding(.top, 16)
        }
        .tracksProviderSignIns(model)
        .task(id: model.apiKeyServiceKeys) { signIn.answerInline(model.apiKeyServiceKeys) }
        .onDisappear { signIn.answerInline([]) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localEngineProviders")
    }

    private var header: some View {
        VStack(spacing: 0) {
            Text("Step 1 of 2")
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textTertiary)
                .padding(.bottom, 8)
                .accessibilityIdentifier("localEngineProvidersStep")
            Text("Pick the AI behind Pal")
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("localEngineProvidersTitle")
            if !showsAll {
                Text("Pal needs one AI provider to reply. Your key stays on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded && model.loadFailed {
            loadFailure
        } else if !model.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .accessibilityIdentifier("localEngineProvidersLoading")
        } else if showsAll {
            allProviders
        } else {
            shortList
        }
    }

    private var shortList: some View {
        MacOverflowScroll {
            VStack(spacing: 12) {
                MacCard(identifier: "localEngineProviderList") {
                    ForEach(model.firstRunChoices) { choice in
                        ProviderChoiceRow(choice: choice.provider, name: choice.name, blurb: choice.blurb, keyPage: choice.keyPage, model: model)
                    }
                }
                Button("More providers…") { showsAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(height: 28)
                    .accessibilityIdentifier("localEngineProvidersMore")
            }
            .padding(.top, 14)
        }
    }

    private var allProviders: some View {
        @Bindable var model = model
        let providers = model.allSignInProviders
        return VStack(spacing: 0) {
            FloatingSearchBar(
                text: $model.query,
                prompt: String(localized: "Search providers"),
                accessibilityLabel: String(localized: "Search providers"),
                accessibilityIdentifier: "localEngineProvidersSearch"
            )
            .padding(.top, 12)
            MacOverflowScroll {
                VStack(spacing: 12) {
                    if providers.isEmpty {
                        Text(ModelProvidersModel.noMatchText)
                            .font(.system(size: 13))
                            .foregroundStyle(PalTokens.textSecondary)
                            .padding(.top, 12)
                            .accessibilityIdentifier("localEngineProvidersNoMatch")
                    } else {
                        MacCard(identifier: "localEngineProviderCatalogue") {
                            ForEach(providers) { provider in
                                ProviderChoiceRow(choice: provider, name: provider.name, blurb: nil, keyPage: nil, model: model)
                            }
                        }
                    }
                    Button("Back to the short list") {
                        model.query = ""
                        showsAll = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(height: 28)
                    .accessibilityIdentifier("localEngineProvidersLess")
                }
                .padding(.top, 12)
            }
        }
    }

    private var loadFailure: some View {
        VStack(spacing: 6) {
            Text("Couldn't load providers")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityIdentifier("localEngineProvidersFailureTitle")
            Text("Pal on this Mac didn't answer. It may still be starting.")
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await model.load() } }
                .glassButtonStyle()
                .buttonBorderShape(.capsule)
                .disabled(model.isLoading)
                .padding(.top, 8)
                .accessibilityIdentifier("localEngineProvidersRetry")
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localEngineProvidersFailure")
    }
}

private enum ProviderRowMode {
    case connected
    case action(String)
    case starting
    case keyEntry(ServiceSignInDialog)
    case browser

    static func resolve(provider: ModelProvider, title: String?, status: ModelProvidersModel.RowStatus, dialog: ServiceSignInDialog?) -> Self {
        if provider.state == .set { return .connected }
        guard status == .working(.signingIn) else { return .action(title ?? String(localized: "Sign in")) }
        guard let dialog else { return .starting }
        return dialog.takesKey ? .keyEntry(dialog) : .browser
    }
}

private struct ProviderChoiceRow: View {
    let choice: ModelProvider
    let name: String
    let blurb: String?
    let keyPage: String?
    let model: ModelProvidersModel

    @Environment(ServiceSignInCenter.self) private var signIn
    @Environment(\.hermesTheme) private var theme

    private var key: String { "localEngineProvider-\(choice.id)" }

    private var mode: ProviderRowMode {
        ProviderRowMode.resolve(
            provider: choice,
            title: model.presentation(of: choice).primaryAction,
            status: model.status(of: choice.id),
            dialog: signIn.dialog(for: ModelProvidersClient.serviceKey + choice.id)
        )
    }

    private var failure: String? {
        if case .failed(let text) = model.status(of: choice.id) { text } else { nil }
    }

    var body: some View {
        let mode = mode
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProviderLogoTile(providerID: choice.id, name: name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PalTokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let blurb {
                        Text(blurb)
                            .font(.system(size: 12))
                            .foregroundStyle(PalTokens.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing(mode)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 46)
            if case .keyEntry(let dialog) = mode {
                ProviderKeyEntry(dialog: dialog, name: name, keyPage: keyPage, identifier: key)
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 54)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("\(key)-failure")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(key)
    }

    @ViewBuilder
    private func trailing(_ mode: ProviderRowMode) -> some View {
        switch mode {
        case .connected:
            HStack(spacing: 6) {
                PalIcon("checkmark.circle.fill", ink: .success).font(.system(size: 14))
                Text("Connected").font(.system(size: 13, weight: .semibold)).foregroundStyle(PalTokens.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(key)-connected")
        case .action(let title):
            pill(title, identifier: "\(key)-action") { Task { await model.signIn(choice) } }
                .disabled(model.isSigningInAny)
        case .starting:
            busy(String(localized: "Starting"))
        case .keyEntry:
            pill(String(localized: "Cancel"), identifier: "\(key)-cancel") {
                Task { await signIn.notNow(for: ModelProvidersClient.serviceKey + choice.id) }
            }
        case .browser:
            busy(String(localized: "Waiting for browser"))
        }
    }

    private func pill(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).foregroundStyle(PalTokens.textPrimary)
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier(identifier)
    }

    private func busy(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(title).font(.system(size: 13)).foregroundStyle(PalTokens.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(key)-busy")
    }
}

private struct ProviderKeyEntry: View {
    let dialog: ServiceSignInDialog
    let name: String
    let keyPage: String?
    let identifier: String

    @Environment(ServiceSignInCenter.self) private var signIn
    @Environment(\.hermesTheme) private var theme
    @State private var text = ""

    private var entry: SecretEntryState { ServiceSignInWording.entryState(dialog.phase) }

    private var problem: String? {
        switch entry {
        case .failure(let text): text
        case .expired: entry.statusText
        case .idle, .submitting, .success, .cancelled: nil
        }
    }

    private var isChecking: Bool { entry == .submitting || entry == .success }

    private var canSave: Bool { entry.acceptsInput && SecretEntryInput.trimmed(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SecretField(
                    String(localized: "\(name) key"), prompt: String(localized: "Paste your \(name) key"), text: $text,
                    identifier: "\(identifier)-field"
                )
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textPrimary)
                .disabled(!entry.acceptsInput)
                .onSubmit(save)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(PalTokens.content, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(problem == nil ? PalTokens.fieldBorder : Color(theme.palette.destructive), lineWidth: 1)
                )
                Button(action: save) {
                    HStack(spacing: 6) {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text(isChecking ? String(localized: "Checking") : String(localized: "Save"))
                            .font(.system(size: 13))
                            .foregroundStyle(PalTokens.textPrimary)
                    }
                }
                .glassButtonStyle()
                .buttonBorderShape(.capsule)
                .disabled(!canSave)
                .accessibilityIdentifier("\(identifier)-save")
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .accessibilityIdentifier("\(identifier)-problem")
            } else if let keyPage {
                Text("Get a key at \(keyPage)")
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textTertiary)
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PalTokens.hover)
        .onChange(of: entry) { _, new in
            if new.requiresEmptyField { text = "" }
        }
    }

    private func save() {
        guard entry.acceptsInput, let value = SecretEntryInput.trimmed(text) else { return }
        text = ""
        let service = dialog.service
        Task { await signIn.submitCredential(SecretString(value), for: service) }
    }
}

#endif
