import PalDesign
import PalRoster
import SwiftUI

struct CreateBotSheet: View {
    @Bindable var model: CreateBotModel
    let roster: RosterModel
    let router: AppRouter

    @FocusState private var nameFocused: Bool

    var body: some View {
        SheetChrome(
            title: String(localized: "Create New Bot"),
            surface: .grouped,
            accessibilityIdentifier: "createBotSheet",
            onLeading: { router.dismissSheet() }
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    CreateBotPreview(spec: model.spec)
                        .frame(width: PalMetrics.createPreviewBox, height: PalMetrics.createPreviewBox)
                        .padding(.top, 33)
                    CreateBotNameField(model: model, focused: $nameFocused)
                        .padding(.top, 60)
                    BotLookPicker(shape: $model.shape, colorHex: $model.colorHex, seed: model.seed)
                        .padding(.top, 26)
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                CreateBotConfirmButton(model: model, roster: roster, router: router) { nameFocused = false }
            }
        }
        .presentationDetents([.fraction(PalMetrics.createSheetDetentFraction)])
        .presentationCornerRadius(PalMetrics.sheetRadius)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(model.isCreating)
    }
}

private struct CreateBotNameField: View {
    @Bindable var model: CreateBotModel
    var focused: FocusState<Bool>.Binding

    @Environment(\.hermesTheme) private var theme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(spacing: 8) {
            TextField(
                "",
                text: $model.name,
                prompt: Text("Name your Bot").foregroundStyle(PalTokens.textTertiary)
            )
            .hermesText(.nameField)
            .multilineTextAlignment(.center)
            .foregroundStyle(PalTokens.textPrimary)
            .focused(focused)
            .submitLabel(.done)
            .onSubmit { focused.wrappedValue = false }
            .frame(height: PalMetrics.nameFieldHeight)
            .background(PalTokens.elevated, in: shape)
            .overlay(shape.strokeBorder(PalTokens.fieldBorder, lineWidth: 1))
            .contentShape(shape)
            .onTapGesture { focused.wrappedValue = true }
            .accessibilityLabel(Text("Bot name"))
            .accessibilityIdentifier("botNameField")
            if let message = errorMessage {
                Text(message)
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(Color(theme.palette.destructive))
                    .accessibilityIdentifier("createBotError")
            }
        }
        .padding(.horizontal, PalMetrics.nameFieldHorizontalMargin)
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

private struct CreateBotConfirmButton: View {
    let model: CreateBotModel
    let roster: RosterModel
    let router: AppRouter
    let willCreate: () -> Void

    var body: some View {
        Button {
            willCreate()
            Task {
                guard let created = await model.create(in: roster) else { return }
                router.openChat(botName: created.name)
            }
        } label: {
            HStack(spacing: 8) {
                if model.isCreating { ProgressView().controlSize(.small) }
                Text("Create").hermesText(.largePill)
            }
            .frame(maxWidth: .infinity)
            .frame(height: PalMetrics.createButtonHeight)
        }
        .buttonStyle(CreateButtonStyle())
        .disabled(!model.canCreate)
        .padding(.horizontal, 29)
        .padding(.bottom, PalMetrics.createButtonBottomPadding)
        .accessibilityIdentifier("createBotConfirm")
    }
}

struct CreateBotPreview: View {
    let spec: BotAvatarSpec

    private enum Phase { case entering, live }

    @State private var phase = Phase.entering
    @State private var mood = AvatarMood.idle
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let enterDuration: Duration = .milliseconds(900)
    private static let restDuration: Duration = .milliseconds(2600)

    var body: some View {
        ZStack {
            switch phase {
            case .entering:
                EnteringDot(color: dotColor)
                    .transition(.opacity)
            case .live:
                BotAvatarView(spec: spec, size: PalMetrics.createPreviewFrame, mood: mood)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.62), value: phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: bounce) { await run() }
        .onChange(of: spec) { bounce += 1 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Bot preview"))
        .accessibilityIdentifier("createBotPreview")
    }

    private var dotColor: Color {
        if case .shape(.blob(let blob)) = spec, case .custom(let color) = blob.body { return color.swiftUIColor }
        return .orange
    }

    private func run() async {
        if phase == .entering {
            if !reduceMotion { try? await Task.sleep(for: Self.enterDuration) }
            phase = .live
        }
        while !Task.isCancelled {
            mood = reduceMotion ? .idle : .done
            if reduceMotion { return }
            try? await Task.sleep(for: .seconds(AvatarMood.doneDuration + 0.1))
            mood = .idle
            try? await Task.sleep(for: Self.restDuration)
        }
    }
}

private struct EnteringDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let pulse = 1 + 0.08 * sin(t * 9)
                let radius = 15.0 * pulse
                canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                for (index, orbit) in [(r: 34.0, size: 4.5, speed: 5.0), (r: 30.0, size: 6.5, speed: -4.0)].enumerated() {
                    let angle = t * orbit.speed + Double(index) * 2.4
                    let point = CGPoint(x: center.x + cos(angle) * orbit.r, y: center.y + sin(angle) * orbit.r * 0.8)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: point.x - orbit.size, y: point.y - orbit.size, width: orbit.size * 2, height: orbit.size * 2)),
                        with: .color(color.opacity(0.75))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CreateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hermesTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(isEnabled ? theme.palette.chipSelectedText : theme.palette.sheetBackground))
            .background(
                Color(isEnabled ? theme.palette.chipSelectedFill : theme.palette.pillDimmedText),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}
