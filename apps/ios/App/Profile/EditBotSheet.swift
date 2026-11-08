import HermesDesign
import SwiftUI

struct EditBotSheet: View {
    @Bindable var model: EditBotModel
    let onClose: () -> Void

    @Environment(\.hermesTheme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        SheetChrome(
            title: String(localized: "Edit"),
            accessibilityIdentifier: "editBotSheet",
            onLeading: onClose,
            trailing: {
                PillButton(
                    String(localized: "Save"),
                    kind: model.canSave ? .accent : .dimmed,
                    isBusy: model.isSaving,
                    accessibilityIdentifier: "editBotSave"
                ) {
                    Task { if await model.save() { onClose() } }
                }
            },
            content: {
                ScrollView {
                    VStack(spacing: 24) {
                        BotAvatarView(spec: model.look.spec, size: 88, animated: false)
                            .padding(.top, 4)
                        TextField("", text: $model.name, prompt: Text("Name"))
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                            .padding(.horizontal, HermesMetrics.rowInset)
                            .frame(height: HermesMetrics.rowMinimumHeight)
                            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
                            .padding(.horizontal, HermesMetrics.screenMargin)
                            .accessibilityLabel(Text("Name"))
                            .accessibilityIdentifier("editBotName")
                        BotLookEditor(look: $model.look)
                            .padding(.horizontal, HermesMetrics.screenMargin)
                        if let failure = model.failure {
                            Text(failure)
                                .hermesText(.rowSubtitle)
                                .foregroundStyle(Color(theme.palette.destructive))
                                .accessibilityIdentifier("editBotFailure")
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }
}
