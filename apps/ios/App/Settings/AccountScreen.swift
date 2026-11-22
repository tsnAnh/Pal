import PalDesign
import PalSettings
import PhotosUI
import SwiftUI

struct AccountScreen: View {
    let hub: SettingsHub
    let connection: ConnectionModel
    let back: () -> Void

    @Environment(\.hermesTheme) private var theme
    @State private var confirmingSignOut = false
    @State private var confirmingAdd = false
    @State private var choosingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var cropping: OwnerPhotoCropModel?
    @State private var isWorking = false

    private var owner: OwnerProfile { hub.owner }

    private var name: String { connection.userName.isEmpty ? "Account" : connection.userName }

    var body: some View {
        SettingsPage(title: "Account", identifier: "accountScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "accountCurrentCard") {
                LeadingSettingsRow(
                    title: name, subtitle: connection.gatewayHost, accessibilityIdentifier: "accountCurrentRow"
                ) {
                    InitialAvatar(initial: owner.initial(fallback: connection.userInitial), photo: owner.photo)
                }
                .frame(minHeight: 70)
            }
            GroupedCard(accessibilityIdentifier: "accountPhotoCard") {
                LeadingSettingsRow(
                    title: owner.photo == nil ? String(localized: "Add photo") : String(localized: "Change photo"),
                    leadingSpacing: 14, accessibilityIdentifier: "accountChangePhotoRow",
                    action: { choosingPhoto = true },
                    leading: {
                        PalIcon("photo")
                            .font(.system(size: 17, weight: .light))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                    }
                )
                .disabled(isWorking)
                if owner.photo != nil {
                    LeadingSettingsRow(
                        title: String(localized: "Remove photo"), leadingSpacing: 14, accessibilityIdentifier: "accountRemovePhotoRow",
                        action: removePhoto,
                        leading: {
                            PalIcon("trash")
                                .font(.system(size: 17, weight: .light))
                                .frame(width: 22)
                                .accessibilityHidden(true)
                        }
                    )
                    .disabled(isWorking)
                }
            }
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                SectionCaption("Switch Account", accessibilityIdentifier: "accountSwitchCaption")
                GroupedCard(accessibilityIdentifier: "accountSwitchCard") {
                    SettingsRow(
                        title: name, trailing: .none, accessibilityIdentifier: "accountSwitchCurrent"
                    )
                    .overlay(alignment: .trailing) {
                        PalIcon("checkmark")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.trailing, PalMetrics.rowInset)
                            .accessibilityHidden(true)
                    }
                    LeadingSettingsRow(
                        title: "Add Account", leadingSpacing: 14, accessibilityIdentifier: "accountAddRow",
                        action: { confirmingAdd = true }
                    ) {
                        PalIcon("plus")
                            .font(.system(size: 20, weight: .light))
                            .frame(width: 22)
                            .accessibilityHidden(true)
                    }
                }
            }
            GroupedCard(accessibilityIdentifier: "accountSignOutCard") {
                SettingsRow.destructive("Sign Out", accessibilityIdentifier: "accountSignOutRow", action: { confirmingSignOut = true })
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task { await prepare(item) }
        }
        .sheet(item: $cropping) { model in
            SheetChrome(
                title: String(localized: "Position your photo"), accessibilityIdentifier: "ownerPhotoCropSheet",
                onLeading: { cropping = nil },
                content: {
                    OwnerPhotoCropStep(
                        model: model, showsHeading: false, showsCancel: false, cropHeight: 380,
                        done: { cropping = nil }, cancel: { cropping = nil }
                    )
                    .padding(.horizontal, PalMetrics.screenMargin)
                    .padding(.top, 8)
                }
            )
            .interactiveDismissDisabled(model.isBusy)
        }
        .macConfirm(isPresented: $confirmingSignOut) {
            MacDialogContent(
                String(localized: "Sign out of Pal on this device?"),
                actions: [
                    MacDialogAction("Sign Out", role: .destructive) { Task { await connection.signOut() } },
                    MacDialogAction("Cancel", role: .cancel),
                ]
            )
        }
        .macConfirm(isPresented: $confirmingAdd) {
            MacDialogContent(
                String(localized: "Signing in with another account replaces this one on this device."),
                actions: [
                    MacDialogAction("Continue", role: .destructive) { Task { await connection.signOut() } },
                    MacDialogAction("Cancel", role: .cancel),
                ]
            )
        }
    }

    private func prepare(_ item: PhotosPickerItem) async {
        isWorking = true
        defer { isWorking = false }
        let source = try? await item.loadTransferable(type: Data.self)
        let image = await Task.detached(priority: .userInitiated) { source.flatMap { try? OwnerPhotoImage.decode($0) } }.value
        guard let image else {
            hub.message = OwnerPhotoCopy.unusable
            return
        }
        let owner = owner
        cropping = OwnerPhotoCropModel(image: image) { jpeg in try await owner.setPhoto(jpeg) }
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
