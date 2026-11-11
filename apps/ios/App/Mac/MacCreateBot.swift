#if os(macOS)
import PalDesign
import PalRoster
import SwiftUI

struct MacCreateBot: View {
    @Bindable var model: CreateBotModel
    let roster: RosterModel
    let router: AppRouter

    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Create New Bot")
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .frame(height: 49)
                .accessibilityAddTraits(.isHeader)
            PalHairline(color: PalTokens.panelBorder)
            MacCreateBotPreview(model: model)
                .padding(.top, 9)
            MacCreateBotNameField(model: model, focused: $nameFocused, onSubmit: create)
                .padding(.top, 9)
            MacCreateBotShapeGrid(model: model)
                .padding(.top, 15)
            MacCreateBotSwatches(model: model)
                .padding(.top, 16)
            Spacer(minLength: 0)
            PalHairline(color: PalTokens.panelBorder)
            MacCreateBotFooter(model: model, router: router, onCreate: create)
        }
        .task {
            for _ in 0..<10 where !nameFocused {
                nameFocused = true
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        .interactiveDismissDisabled(model.isCreating)
    }

    private func create() {
        guard model.canCreate else { return }
        nameFocused = false
        Task {
            guard let created = await model.create(in: roster) else { return }
            router.openChat(botName: created.name)
        }
    }
}

private struct MacCreateBotPreview: View {
    let model: CreateBotModel

    var body: some View {
        CreateBotPreview(spec: model.spec)
            .frame(width: PalMetrics.createPreviewFrame, height: PalMetrics.createPreviewFrame)
            .scaleEffect(0.6)
            .frame(width: 100, height: 100)
    }
}

private struct MacCreateBotNameField: View {
    @Bindable var model: CreateBotModel
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            TextField("", text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(PalTokens.textPrimary)
                .focused(focused)
                .onSubmit(onSubmit)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay {
                    if model.name.isEmpty {
                        Text("Name your Bot")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PalTokens.textTertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PalTokens.fieldBorder, lineWidth: 1))
                .accessibilityLabel(Text("Bot name"))
                .accessibilityIdentifier("botNameField")
            if let message = errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(theme.palette.destructive))
                    .accessibilityIdentifier("createBotError")
            }
        }
        .padding(.horizontal, 15)
    }

    private var errorMessage: LocalizedStringKey? {
        if model.isNameRejected { return "Use letters or numbers, and a name that isn't reserved." }
        switch model.failure {
        case .nameTaken: return "A bot with that name already exists."
        case .invalidName: return "That name can't be used."
        case .permissionDenied: return "This device isn't allowed to create bots."
        case .unavailable: return "Couldn't create the bot. Try again."
        case nil: return nil
        }
    }
}

private struct MacCreateBotShapeGrid: View {
    let model: CreateBotModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(BotLookCatalog.shapeRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { kind in shapeCell(kind) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botLookPicker")
    }

    private func shapeCell(_ kind: BlobKind) -> some View {
        let selected = kind == model.shape
        let spec = BotAvatarSpec(
            name: model.seed,
            meta: BotAvatarMeta(shape: BotLookCatalog.shapeString(seed: model.seed, kind: kind), color: model.colorHex, custom: true)
        )
        let outline = selected ? AvatarOutline(gap: 1, thickness: 2, color: PalTokens.borderStrong) : nil
        return Button { model.shape = kind } label: {
            BotAvatarView(spec: spec, size: 43, animated: false, outline: outline)
                .frame(width: 51, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BotLookCatalog.displayName(of: kind)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("botShape-\(kind.rawValue)")
    }
}

private struct MacCreateBotSwatches: View {
    let model: CreateBotModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(BotLookCatalog.swatchRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(row) { option in swatch(option) }
                }
                .frame(height: 37)
            }
        }
    }

    private func swatch(_ option: BotLookCatalog.Swatch) -> some View {
        let selected = option.hex.caseInsensitiveCompare(model.colorHex) == .orderedSame
        let color = AvatarColor(css: option.hex)?.swiftUIColor ?? .gray
        return Button { model.colorHex = option.hex } label: {
            ZStack {
                Circle().fill(color).frame(width: 22, height: 22)
                if selected {
                    Circle().strokeBorder(Color(theme.palette.selectionRing), lineWidth: 1.5).frame(width: 31, height: 31)
                }
            }
            .frame(width: 23, height: 23)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(option.name)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("botSwatch-\(option.hex.dropFirst())")
    }
}

private struct MacCreateBotFooter: View {
    let model: CreateBotModel
    let router: AppRouter
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Spacer()
            Button("Cancel") { router.dismissSheet() }
                .buttonStyle(.palPill(horizontalPadding: 14))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("createBotCancel")
            Button {
                onCreate()
            } label: {
                HStack(spacing: 6) {
                    if model.isCreating { ProgressView().controlSize(.small) }
                    Text("Create")
                }
            }
            .buttonStyle(.palPill(
                horizontalPadding: 14,
                fill: model.canCreate ? PalTokens.inverseFill : PalTokens.fieldBorder,
                textColor: model.canCreate ? PalTokens.inverseText : PalTokens.textTertiary,
                disabledOpacity: 1
            ))
            .disabled(!model.canCreate)
            .accessibilityIdentifier("createBotConfirm")
        }
        .padding(.trailing, 11)
        .frame(height: 52)
    }
}
#endif
