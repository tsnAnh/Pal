import HermesDesign
import PhotosUI
import SwiftUI

struct EditBotSheet: View {
    @Bindable var model: EditBotModel
    let onClose: () -> Void

    @Environment(\.hermesTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var nameFocused: Bool
    @State private var isPhotoPickerPresented = false
    @State private var pickedPhoto: PhotosPickerItem?

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
                        BotAvatarView(spec: model.previewSpec, size: 88, animated: scenePhase == .active)
                            .padding(.top, 4)
                            .accessibilityIdentifier("editBotPreview")
                        photoControls
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
                        BotLookPicker(shape: shapeBinding, colorHex: $model.look.colorHex, seed: model.look.seed)
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

    private var shapeBinding: Binding<BlobKind> {
        Binding(get: { model.look.kind }, set: { model.pickShape($0) })
    }

    private var photoControls: some View {
        HStack(spacing: 8) {
            avatarAction(String(localized: "Randomize"), id: "editBotRandomize") { model.randomize() }
            avatarAction(String(localized: "Upload photo"), id: "editBotUploadPhoto") { isPhotoPickerPresented = true }
            if model.hasPhoto {
                avatarAction(String(localized: "Remove photo"), id: "editBotRemovePhoto") { model.removePhoto() }
            }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task { await model.choosePhoto(try? await item.loadTransferable(type: Data.self)) }
        }
    }

    private func avatarAction(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title) }
            .buttonStyle(.pill())
            .accessibilityIdentifier(id)
    }
}
