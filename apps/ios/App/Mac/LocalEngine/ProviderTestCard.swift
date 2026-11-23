#if os(macOS)
import PalDesign
import SwiftUI

struct ProviderTestCard: View {
    let face: ProviderTestFace
    let signedInTitle: String
    let providerName: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                indicator
                Text(face.title)
                    .fontWeight(.semibold)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityIdentifier("providerTestStateTitle")
            }
            if let detail = face.detail {
                Text(detail)
                    .hermesText(.botPreview)
                    .foregroundStyle(face.tone == .failure ? Color(theme.palette.destructive) : PalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("providerTestStateDetail")
            }
            if face.showsChecklist {
                checklist
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .providerGlass()
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(face.slug))
        .accessibilityIdentifier("providerTestState")
    }

    @ViewBuilder
    private var indicator: some View {
        switch face.indicator {
        case .none: EmptyView()
        case .spinner: ProgressView().controlSize(.small)
        case .check: PalIcon("checkmark.circle.fill", ink: .success)
        case .cross: PalIcon("xmark.circle.fill", ink: .destructive)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(signedInTitle) { PalIcon("checkmark.circle.fill", ink: .success) }
            step(String(localized: "Reached \(providerName)")) { PalIcon("circle", ink: .tertiary) }
            step(String(localized: "Waiting for a reply…")) { ProgressView().controlSize(.small) }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providerTestChecklist")
    }

    private func step<Mark: View>(_ title: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 8) {
            mark().frame(width: 16)
            Text(title)
                .hermesText(.botPreview)
                .foregroundStyle(PalTokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ProviderModelList: View {
    let model: ProviderOnboardingModel
    let providerID: String

    private var name: String { model.displayName(providerID) }

    var body: some View {
        switch model.catalog {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading models…")
            }
            .hermesText(.botPreview)
            .foregroundStyle(PalTokens.textTertiary)
            .padding(.vertical, 12)
            .accessibilityIdentifier("providerTestModelsLoading")
        case .unavailable:
            manualField
        case .loaded(let names):
            loaded(names)
        }
    }

    private var manualField: some View {
        VStack(alignment: .leading, spacing: 8) {
            PalGlassTextField(
                String(localized: "Model name"),
                text: Binding(get: { model.manualModel }, set: { model.setManualModel($0) }),
                prompt: Text("Model name"), identifier: "providerTestModelField")
            Text("Pal could not read the model list. Type the name of the model to use.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textTertiary)
                .padding(.leading, 2)
        }
    }

    private func loaded(_ names: [String]) -> some View {
        let defaultName = names.first
        return LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(model.visibleModels, id: \.self) { entry in
                ProviderModelRow(
                    providerID: providerID, providerName: name, model: entry, isDefault: entry == defaultName,
                    isSelected: entry == model.selectedModel, isEnabled: model.modelsAreEditable
                ) { model.pick(model: entry) }
            }
            if model.hiddenModelCount > 0 {
                Button { model.showsAllModels = true } label: {
                    Text("Show all \(names.count) models")
                        .hermesText(.botPreview)
                        .foregroundStyle(PalTokens.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("providerTestShowAllModels")
            }
        }
    }
}

struct ProviderModelRow: View {
    let providerID: String
    let providerName: String
    let model: String
    let isDefault: Bool
    let isSelected: Bool
    let isEnabled: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ProviderLogo.tile(for: providerID, name: providerName)
                Text(model)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isDefault {
                    Text("Default")
                        .hermesText(.timestamp)
                        .foregroundStyle(PalTokens.textTertiary)
                        .accessibilityIdentifier("providerTestModel-\(model)-default")
                }
                Spacer(minLength: 0)
                if isSelected {
                    PalIcon("checkmark", ink: .primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: ProviderRow.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .providerGlass()
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("providerTestModel-\(model)")
    }
}
#endif
