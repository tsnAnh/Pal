#if os(macOS)
import PalDesign
import PalSettings
import SwiftUI

struct MacAboutYouCard: View {
    let hub: SettingsHub

    @State private var nameDraft = ""
    @State private var cropping: OwnerPhotoCropModel?
    @State private var isWorking = false
    @FocusState private var nameFocused: Bool

    private var owner: OwnerProfile { hub.owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacCaption("About you")
            MacCard(identifier: "settingsAboutYouCard") {
                MacRow(title: String(localized: "Name"), identifier: "settingsAboutYouNameRow") {
                    TextField("Your name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textPrimary)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .frame(minWidth: 150, maxWidth: 220)
                        .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PalTokens.fieldBorder, lineWidth: 1))
                        .accessibilityLabel(Text("Name"))
                        .accessibilityIdentifier("settingsAboutYouNameField")
                }
                PalHairline(color: PalTokens.divider).padding(.horizontal, 13)
                photoRow
            }
            MacFootnote(
                text: String(localized: "Your bots use this name and photo when they talk to you. The photo is optional."),
                identifier: "settingsAboutYouFootnote"
            )
        }
        .onChange(of: owner.name, initial: true) { _, name in
            if !nameFocused { nameDraft = name }
        }
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
        }
        .macSheet(item: $cropping) { model in
            OwnerPhotoCropSheet(model: model, done: { cropping = nil }, cancel: { cropping = nil })
        }
    }

    private var photoRow: some View {
        MacRow(title: String(localized: "Photo"), identifier: "settingsAboutYouPhotoRow") {
            HStack(spacing: 12) {
                InitialAvatar(initial: owner.initial(fallback: ""), diameter: 36, photo: owner.photo)
                    .accessibilityHidden(true)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if owner.photo == nil {
                            pill("Add photo", icon: "camera", identifier: "settingsAboutYouAddPhoto", action: choosePhoto)
                        } else {
                            pill("Change", icon: "photo", identifier: "settingsAboutYouChangePhoto", action: choosePhoto)
                            pill("Remove", icon: "trash", identifier: "settingsAboutYouRemovePhoto", action: removePhoto)
                        }
                    }
                }
            }
        }
    }

    private func pill(_ title: LocalizedStringKey, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PalIcon(icon, ink: .onInverseFill).font(.system(size: 13))
                Text(title).font(.system(size: 12.5))
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .disabled(isWorking)
        .accessibilityIdentifier(identifier)
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != owner.name else {
            nameDraft = owner.name
            return
        }
        let owner = owner
        Task {
            do {
                try await owner.setName(trimmed)
            } catch is CancellationError {
            } catch {
                hub.message = SettingsFailure(error).message
            }
            if !nameFocused { nameDraft = owner.name }
        }
    }

    private func choosePhoto() {
        guard let url = MacOwnerPhotoPicker.chooseImage() else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            guard let image = await MacOwnerPhotoPicker.loadImage(url) else {
                hub.message = OwnerPhotoCopy.unusable
                return
            }
            let owner = owner
            cropping = OwnerPhotoCropModel(image: image) { jpeg in try await owner.setPhoto(jpeg) }
        }
    }

    private func removePhoto() {
        isWorking = true
        let owner = owner
        Task {
            defer { isWorking = false }
            do {
                try await owner.setPhoto(nil)
            } catch is CancellationError {
            } catch {
                hub.message = SettingsFailure(error).message
            }
        }
    }
}

struct OwnerPhotoCropSheet: View {
    let model: OwnerPhotoCropModel
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        MacOverflowScroll {
            OwnerPhotoCropStep(model: model, done: done, cancel: cancel)
                .frame(maxWidth: 480)
                .padding(.top, 36)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .macSheetDismissDisabled(model.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ownerPhotoCropSheet")
    }
}
#endif
