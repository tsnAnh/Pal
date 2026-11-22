#if os(macOS)
import PalBotProfile
import PalDesign
import PalRoster
import SwiftUI

struct MacCreateBot: View {
    @Bindable var model: CreateBotModel
    let roster: RosterModel
    let router: AppRouter

    @FocusState private var focus: MacCreateBotField?

    var body: some View {
        ViewThatFits(in: .vertical) {
            layout(scrolls: false)
            layout(scrolls: true)
        }
        .frame(width: MacModalSizing.createBotWidth)
        .task {
            for _ in 0..<10 where focus != .name {
                focus = .name
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private static let inset: CGFloat = 24
    private static let sectionSpacing: CGFloat = 18

    @ViewBuilder
    private func layout(scrolls: Bool) -> some View {
        if scrolls {
            ScrollView { content }
                .scrollIndicators(.never)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: Self.sectionSpacing) {
            Text("Create New Bot")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PalMetrics.macPanelTitleClearance + PalMetrics.macPanelCloseLeadingInset - Self.inset)
                .accessibilityAddTraits(.isHeader)
            Group {
                MacCreateBotPreview(model: model)
                MacCreateBotNameField(model: model, focus: $focus, onSubmit: create)
                MacCreateBotShapeGrid(model: model, focus: $focus, onSubmit: create)
                MacCreateBotSwatches(model: model, focus: $focus, onSubmit: create)
                if let message = MacCreateBotNameField.failureBanner(model.failure) {
                    MacCreateBotBanner(message: message)
                }
            }
            .disabled(model.isCreating)
            MacCreateBotActions(model: model, router: router, onCreate: create)
        }
        .padding(Self.inset)
    }

    private func create() {
        guard model.gate.canCreate else { return }
        focus = nil
        Task {
            guard let created = await model.create(in: roster, startsFresh: true) else { return }
            router.openChat(botName: created.name)
        }
    }
}

enum MacCreateBotField: Hashable {
    case name
    case shapes
    case colors
}

private struct MacCreateBotPreview: View {
    let model: CreateBotModel

    var body: some View {
        CreateBotPreview(spec: model.spec)
            .frame(width: PalMetrics.createPreviewFrame, height: PalMetrics.createPreviewFrame)
            .scaleEffect(0.55)
            .frame(width: 110, height: 110)
    }
}

private struct MacCreateBotNameField: View {
    @Bindable var model: CreateBotModel
    var focus: FocusState<MacCreateBotField?>.Binding
    let onSubmit: () -> Void

    @Environment(\.hermesTheme) private var theme

    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(spacing: 6) {
            TextField("", text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .focused(focus, equals: .name)
                .onSubmit(onSubmit)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PalTokens.chipFill, in: fieldShape)
                .overlay {
                    if model.name.isEmpty {
                        Text("Name your Bot")
                            .font(.system(size: 14))
                            .foregroundStyle(PalTokens.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(fieldShape.strokeBorder(borderColor, lineWidth: 1))
                .accessibilityLabel(Text("Bot name"))
                .accessibilityIdentifier("botNameField")
            hint
        }
    }

    @ViewBuilder
    private var hint: some View {
        if let message = Self.inlineError(model) {
            hintText(message)
                .foregroundStyle(Color(theme.palette.destructive))
                .accessibilityIdentifier("createBotError")
        } else if let reason = Self.gateReason(model.gate) {
            hintText(reason)
                .foregroundStyle(PalTokens.textTertiary)
                .accessibilityIdentifier("createBotReason")
        }
    }

    private func hintText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func gateReason(_ gate: CreateBotGate) -> LocalizedStringKey? {
        switch gate {
        case .pickAnotherName: "Pick another name"
        case .needsName, .ready, .creating: nil
        }
    }

    private var borderColor: Color {
        Self.inlineError(model) == nil ? PalTokens.fieldBorder : Color(theme.palette.destructive)
    }

    static func inlineError(_ model: CreateBotModel) -> LocalizedStringKey? {
        if model.isNameRejected { return "Use letters or numbers, and a name that isn't reserved." }
        switch model.failure {
        case .nameTaken: return "A bot with that name already exists."
        case .invalidName: return "That name can't be used."
        case .permissionDenied, .unavailable, nil: return nil
        }
    }

    static func failureBanner(_ failure: CreateBotModel.Failure?) -> LocalizedStringKey? {
        switch failure {
        case .permissionDenied: "This device isn't allowed to create bots."
        case .unavailable: "Couldn't create the bot. Your choices are kept; try again."
        case .nameTaken, .invalidName, nil: nil
        }
    }
}

private struct MacCreateBotBanner: View {
    let message: LocalizedStringKey

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(PalTokens.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(theme.palette.destructive).opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(theme.palette.destructive).opacity(0.45), lineWidth: 1))
            .accessibilityIdentifier("createBotFailure")
    }
}

private extension View {
    func lookKeys(
        focus: FocusState<MacCreateBotField?>.Binding,
        field: MacCreateBotField,
        onMove: @escaping (LookDirection) -> Void,
        onSubmit: @escaping () -> Void
    ) -> some View {
        focusable()
            .focused(focus, equals: field)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { onMove(.left); return .handled }
            .onKeyPress(.rightArrow) { onMove(.right); return .handled }
            .onKeyPress(.upArrow) { onMove(.up); return .handled }
            .onKeyPress(.downArrow) { onMove(.down); return .handled }
            .onKeyPress(.return) { onSubmit(); return .handled }
    }
}

private struct MacCreateBotShapeGrid: View {
    let model: CreateBotModel
    var focus: FocusState<MacCreateBotField?>.Binding
    let onSubmit: () -> Void

    private static let cell: CGFloat = 54
    private static let avatar: CGFloat = 42
    private static let spacing: CGFloat = 6

    private var chosenColor: Color { AvatarColor(css: model.colorHex)?.swiftUIColor ?? .gray }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(BotLookCatalog.shapeRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.spacing) {
                    ForEach(row, id: \.self) { kind in shapeCell(kind) }
                }
            }
        }
        .lookKeys(focus: focus, field: .shapes, onMove: move, onSubmit: onSubmit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Shape"))
        .accessibilityIdentifier("botLookPicker")
    }

    private func move(_ direction: LookDirection) {
        let current = BotLookCatalog.shapes.firstIndex(of: model.shape) ?? 0
        model.shape = BotLookCatalog.shapes[BotLookCatalog.move(current, direction, rowLengths: BotLookCatalog.shapeRowLengths)]
    }

    private func shapeCell(_ kind: BlobKind) -> some View {
        let selected = kind == model.shape
        let spec = BotAvatarSpec(
            name: model.seed,
            meta: BotAvatarMeta(shape: BotLookCatalog.shapeString(seed: model.seed, kind: kind), color: model.colorHex, custom: true)
        )
        let frame = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { model.shape = kind } label: {
            BotAvatarView(spec: spec, size: Self.avatar, animated: false)
                .frame(width: Self.cell, height: Self.cell)
                .overlay {
                    if selected { frame.strokeBorder(chosenColor, lineWidth: 2) }
                }
                .overlay {
                    if selected, focus.wrappedValue == .shapes {
                        frame.inset(by: -3).strokeBorder(PalTokens.textPrimary.opacity(0.9), lineWidth: 2)
                    }
                }
                .contentShape(frame)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BotLookCatalog.shapeAccessibilityLabel(kind, isSelected: selected)))
        .accessibilityIdentifier("botShape-\(kind.rawValue)")
    }
}

private struct MacCreateBotSwatches: View {
    let model: CreateBotModel
    var focus: FocusState<MacCreateBotField?>.Binding
    let onSubmit: () -> Void

    private func isSelected(_ option: BotLookCatalog.Swatch) -> Bool {
        option.hex.caseInsensitiveCompare(model.colorHex) == .orderedSame
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(BotLookCatalog.swatchRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { option in swatch(option) }
                }
            }
        }
        .lookKeys(focus: focus, field: .colors, onMove: move, onSubmit: onSubmit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Color"))
        .accessibilityIdentifier("botColourPicker")
    }

    private func move(_ direction: LookDirection) {
        let current = BotLookCatalog.swatches.firstIndex(where: isSelected) ?? 0
        model.colorHex = BotLookCatalog.swatches[BotLookCatalog.move(current, direction, rowLengths: BotLookCatalog.swatchRowLengths)].hex
    }

    private func swatch(_ option: BotLookCatalog.Swatch) -> some View {
        let selected = isSelected(option)
        let color = AvatarColor(css: option.hex)?.swiftUIColor ?? .gray
        return Button { model.colorHex = option.hex } label: {
            ZStack {
                Circle().fill(color).frame(width: 32, height: 32)
                Circle().strokeBorder(PalTokens.borderStrong, lineWidth: 1).frame(width: 32, height: 32)
                if selected {
                    Circle().strokeBorder(color, lineWidth: 2).frame(width: 40, height: 40)
                }
                if selected, focus.wrappedValue == .colors {
                    Circle().strokeBorder(PalTokens.textPrimary.opacity(0.9), lineWidth: 2).frame(width: 46, height: 46)
                }
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BotLookCatalog.swatchAccessibilityLabel(option, isSelected: selected)))
        .accessibilityIdentifier("botSwatch-\(option.hex.dropFirst())")
    }
}

private struct MacCreateBotActions: View {
    let model: CreateBotModel
    let router: AppRouter
    let onCreate: () -> Void

    var body: some View {
        MacModalActions(
            isBusy: model.isCreating,
            canConfirm: model.gate.canCreate,
            confirmTitle: "Create",
            busyTitle: "Creating…",
            cancelIdentifier: "createBotCancel",
            confirmIdentifier: "createBotConfirm",
            onCancel: { router.dismissSheet() },
            onConfirm: onCreate
        )
    }
}
#endif
