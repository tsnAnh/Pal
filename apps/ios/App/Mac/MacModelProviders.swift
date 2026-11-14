#if os(macOS)
import PalBotProfile
import PalDesign
import SwiftUI

struct MacModelProvidersSection: View {
    let hub: SettingsHub

    @State private var model: ModelProvidersModel

    init(hub: SettingsHub) {
        self.hub = hub
        _model = State(initialValue: hub.modelProvidersModel())
    }

    var body: some View {
        MacSectionPage(
            section: .providers,
            accessory: {
                Button("Refresh") { Task { await model.load() } }
                    .buttonStyle(.palPill(height: 28))
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("providersRefreshButton")
            },
            content: { content }
        )
        .task { await model.load() }
        .tracksProviderSignIns(model)
        .providerRemovalConfirmation(model)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded && model.loadFailed {
            MacFailure(message: ModelProvidersModel.loadFailureText) { Task { await model.load() } }
        } else if !model.hasLoaded {
            MacCard(identifier: "providersLoading") { MacLoading() }
        } else {
            MacProviderSearchField(text: $model.query)
            let sections = model.sections
            ForEach(sections) { section in
                MacProviderGroupCard(section: section, model: model)
            }
            if sections.isEmpty {
                MacCard(identifier: "providersNoMatch") {
                    MacEmptyRow(text: LocalizedStringKey(ModelProvidersModel.noMatchText), identifier: "providersNoMatchRow")
                }
            }
            MacFootnote(
                text: model.loadFailed ? ModelProvidersModel.refreshFailureText : ModelProvidersModel.footnoteText,
                identifier: "providersFootnote")
        }
    }
}

private struct MacProviderGroupCard: View {
    let section: ModelProviderSection
    let model: ModelProvidersModel

    private var showsLess: Bool {
        section.group == .onHost && model.showsAllOnHost && section.providers.count > 1 && model.query.isEmpty
    }

    var body: some View {
        let group = section.group.rawValue
        VStack(alignment: .leading, spacing: 0) {
            MacCaption(verbatim: section.group.title).accessibilityIdentifier("modelProviders-\(group)")
            MacCard(identifier: "modelProvidersCard-\(group)") {
                if section.providers.isEmpty {
                    MacEmptyRow(text: LocalizedStringKey(ModelProvidersModel.emptyConnectedText), identifier: "providersEmptyConnected")
                }
                ForEach(Array(section.providers.enumerated()), id: \.element.id) { index, provider in
                    MacProviderRow(provider: provider, face: model.presentation(of: provider), group: section.group, model: model)
                        .overlay(alignment: .bottom) {
                            if index < section.providers.count - 1 || section.hiddenCount > 0 || showsLess {
                                PalHairline(color: PalTokens.hairline).padding(.horizontal, 13)
                            }
                        }
                }
                if section.hiddenCount > 0 {
                    toggle("Show \(section.hiddenCount) more", identifier: "providersShowMore") { model.showsAllOnHost = true }
                } else if showsLess {
                    toggle("Show less", identifier: "providersShowLess") { model.showsAllOnHost = false }
                }
            }
        }
    }

    private func toggle(_ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct MacProviderRow: View {
    let provider: ModelProvider
    let face: ModelProviderFace
    let group: ModelProviderGroup
    let model: ModelProvidersModel

    @Environment(\.hermesTheme) private var theme
    @State private var editingAddress = false

    private var attention: Color { Color(theme.palette.destructive) }

    private var isFailed: Bool {
        if case .failed = face.status { true } else { false }
    }

    var body: some View {
        MacRow(
            title: provider.name, subtitle: face.detail, subtitleColor: isFailed ? attention : PalTokens.textSecondary,
            identifier: "modelProvider-\(provider.id)"
        ) {
            HStack(spacing: 6) {
                if let label = face.stateLabel {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(attention)
                        .accessibilityIdentifier("modelProvider-\(provider.id)-state")
                }
                if model.isWorking(provider.id) {
                    ProgressView().controlSize(.small)
                }
                if face.canEditAddress {
                    MacRowAction(title: String(localized: "Address")) { editingAddress = true }
                        .view(identifier: "modelProvider-\(provider.id)-address")
                        .disabled(model.isWorking(provider.id))
                        .popover(isPresented: $editingAddress, arrowEdge: .bottom) {
                            MacProviderAddressEditor(provider: provider, model: model) { editingAddress = false }
                        }
                }
                if let title = face.primaryAction {
                    MacRowAction(title: title, prominent: group == .available) { Task { await model.signIn(provider) } }
                        .view(identifier: "modelProvider-\(provider.id)-action")
                        .disabled(model.isWorking(provider.id))
                }
                if face.canRemove {
                    MacRowAction(title: String(localized: "Remove")) { model.pendingRemoval = provider }
                        .view(identifier: "modelProvider-\(provider.id)-remove")
                        .disabled(model.isWorking(provider.id))
                }
            }
        }
    }
}

private struct MacProviderAddressEditor: View {
    let provider: ModelProvider
    let model: ModelProvidersModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Address")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PalTokens.textPrimary)
            TextField(
                "Address",
                text: Binding(get: { model.address(for: provider) }, set: { model.setAddress($0, for: provider) }),
                prompt: Text(provider.defaultBaseURL ?? "Address").foregroundStyle(PalTokens.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(PalTokens.textPrimary)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onSubmit(save)
            .disabled(model.isWorking(provider.id))
            .accessibilityIdentifier("modelProvider-\(provider.id)-address-field")
            HStack(spacing: 6) {
                if provider.baseURL != nil {
                    Button("Use Default") { Task { await finish { await model.useDefaultAddress(provider) } } }
                        .buttonStyle(.palPill(height: 24, fontSize: 11))
                        .disabled(model.isWorking(provider.id))
                        .accessibilityIdentifier("modelProvider-\(provider.id)-address-default")
                }
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.palPill(height: 24, fontSize: 11, fill: PalTokens.toggleOn.opacity(0.7)))
                    .disabled(model.isWorking(provider.id) || !model.addressIsDirty(for: provider))
                    .accessibilityIdentifier("modelProvider-\(provider.id)-address-save")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func save() {
        Task { await finish { await model.saveAddress(provider) } }
    }

    private func finish(_ change: () async -> Void) async {
        await change()
        if case .succeeded = model.status(of: provider.id) { dismiss() }
    }
}

private struct MacProviderSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
            TextField("Search providers", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityIdentifier("providersSearchField")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif
