#if os(macOS)
import AppKit
import Foundation
import Observation
import PalDesign
import PalSettings
import SwiftUI

@MainActor
@Observable
final class OwnerIntroModel {
    enum Step {
        case form
        case crop(OwnerPhotoCropModel)
        case saved
    }

    static let nameLimit = 80
    static let savedGreetingDuration = Duration.milliseconds(1200)

    struct Draft {
        let jpeg: Data
        let preview: CGImage
    }

    var name: String {
        didSet {
            if name.count > Self.nameLimit { name = String(name.prefix(Self.nameLimit)) }
        }
    }

    private(set) var step = Step.form
    private(set) var draft: Draft?
    private(set) var isSaving = false
    private(set) var photoProblem: String?
    private(set) var saveProblem: String?

    @ObservationIgnored private let owner: OwnerProfile
    @ObservationIgnored private let finish: (_ saved: Bool) -> Void

    init(owner: OwnerProfile, suggestedName: String, finish: @escaping (_ saved: Bool) -> Void) {
        self.owner = owner
        self.finish = finish
        name = String(suggestedName.prefix(Self.nameLimit))
    }

    static func suggestedName(fullName: String) -> String {
        fullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canContinue: Bool { !isSaving && !trimmedName.isEmpty }

    var letter: String { trimmedName.first(where: \.isLetter).map { String($0).uppercased() } ?? "" }

    var greeting: String {
        String(localized: "Nice to meet you, \(trimmedName).")
    }

    var photo: CGImage? { draft?.preview }

    func choosePhoto() {
        guard !isSaving, let url = MacOwnerPhotoPicker.chooseImage() else { return }
        photoProblem = nil
        Task {
            guard let image = await MacOwnerPhotoPicker.loadImage(url) else {
                photoProblem = OwnerPhotoCopy.unusable
                return
            }
            step = .crop(OwnerPhotoCropModel(image: image) { [weak self] jpeg in try await self?.adopt(jpeg: jpeg) })
        }
    }

    func removePhoto() {
        guard !isSaving else { return }
        draft = nil
        photoProblem = nil
    }

    func cancelCrop() {
        step = .form
    }

    func notNow() {
        guard !isSaving else { return }
        finish(false)
    }

    func escape() {
        if case .crop = step { cancelCrop() } else { notNow() }
    }

    func save() async {
        guard canContinue else { return }
        isSaving = true
        saveProblem = nil
        photoProblem = nil
        defer { isSaving = false }
        do {
            try await owner.setName(trimmedName)
            if let draft, !(try await commit(photo: draft)) { return }
        } catch is CancellationError {
            return
        } catch {
            saveProblem = OwnerPhotoCopy.saveFailed
            return
        }
        step = .saved
        try? await Task.sleep(for: Self.savedGreetingDuration)
        finish(true)
    }

    private func commit(photo draft: Draft) async throws -> Bool {
        do {
            try await owner.setPhoto(draft.jpeg)
            return true
        } catch let failure as SettingsFailure {
            guard case .rejected(let code) = failure, code.hasPrefix("photo_") else { throw failure }
            self.draft = nil
            photoProblem = OwnerPhotoCopy.unusable
            return false
        }
    }

    private func adopt(jpeg: Data) async throws {
        let preview = try await Task.detached(priority: .userInitiated) { try OwnerPhotoImage.decode(jpeg) }.value
        draft = Draft(jpeg: jpeg, preview: preview)
        photoProblem = nil
        step = .form
    }
}

struct OwnerIntroSheet: View {
    let model: OwnerIntroModel

    @Environment(\.hermesTheme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        MacOverflowScroll {
            VStack(spacing: 0) {
                switch model.step {
                case .form: form
                case .crop(let crop):
                    OwnerPhotoCropStep(model: crop, cancel: model.cancelCrop)
                        .padding(.top, 8)
                case .saved: saved
                }
            }
            .frame(maxWidth: 480)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .macSheetDismissDisabled(model.isSaving)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ownerIntro")
    }

    private var form: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Step 2 of 2")
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textTertiary)
                .padding(.bottom, 8)
                .accessibilityIdentifier("ownerIntroStep")
            Text("What should your bots call you?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("ownerIntroTitle")
            Text("They'll use this name when they talk to you. A photo is optional, and you can change both in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)
            InitialAvatar(initial: model.letter, diameter: 96, photo: model.photo)
                .padding(.top, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Your picture"))
                .accessibilityIdentifier("ownerIntroAvatar")
            photoPills
                .padding(.top, 10)
            Text(model.photoProblem ?? " ")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(theme.palette.destructive))
                .multilineTextAlignment(.center)
                .frame(minHeight: 18)
                .padding(.vertical, 4)
                .opacity(model.photoProblem == nil ? 0 : 1)
                .accessibilityIdentifier("ownerIntroPhotoError")
            nameField
            Text(model.saveProblem ?? " ")
                .font(.system(size: 11.5))
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .padding(.top, 6)
                .padding(.leading, 2)
                .opacity(model.saveProblem == nil ? 0 : 1)
                .accessibilityIdentifier("ownerIntroSaveError")
            Spacer(minLength: 12)
            Button { Task { await model.save() } } label: {
                HStack(spacing: 8) {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Text(model.saveProblem == nil ? "Continue" : "Try again")
                }
                .foregroundStyle(PalTokens.inverseText)
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .glassButtonStyle(prominent: true, tint: PalTokens.inverseFill)
            .buttonBorderShape(.capsule)
            .disabled(!model.canContinue)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("ownerIntroContinue")
            Button("Not now") { model.notNow() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textSecondary)
                .frame(height: 32)
                .padding(.top, 6)
                .disabled(model.isSaving)
                .accessibilityIdentifier("ownerIntroNotNow")
        }
        .task {
            for _ in 0..<10 where !nameFocused {
                nameFocused = true
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private var photoPills: some View {
        PalGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                if model.photo == nil {
                    pill("Add photo", icon: "camera", identifier: "ownerIntroAddPhoto", action: model.choosePhoto)
                } else {
                    pill("Change photo", icon: "photo", identifier: "ownerIntroChangePhoto", action: model.choosePhoto)
                    pill("Remove photo", icon: "trash", identifier: "ownerIntroRemovePhoto", action: model.removePhoto)
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
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
        .disabled(model.isSaving)
        .accessibilityIdentifier(identifier)
    }

    private var nameField: some View {
        @Bindable var model = model
        return PalTextField("Your name", text: $model.name)
            .font(.system(size: 14))
            .foregroundStyle(PalTokens.textPrimary)
            .focused($nameFocused)
            .disabled(model.isSaving)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(nameFocused ? PalTokens.textTertiary : PalTokens.fieldBorder, lineWidth: 1)
            )
            .opacity(model.isSaving ? 0.5 : 1)
            .accessibilityLabel(Text("Your name"))
            .accessibilityIdentifier("ownerIntroNameField")
    }

    private var saved: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            InitialAvatar(initial: model.letter, diameter: 104, photo: model.photo)
            HStack(spacing: 6) {
                ForEach(OwnerIntroBlob.allCases) { blob in
                    BotAvatarView(spec: blob.spec, size: blob.diameter, mood: .done, animated: false)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 18)
            Text(model.greeting)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityIdentifier("ownerIntroGreeting")
            Text("Let's get started.")
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.top, 8)
            Spacer(minLength: 0)
            Color.clear.frame(height: 88)
        }
    }
}

private enum OwnerIntroBlob: CaseIterable, Identifiable {
    case pink
    case orange
    case teal

    var id: Self { self }

    var diameter: CGFloat { self == .orange ? 40 : 34 }

    var spec: BotAvatarSpec {
        let (kind, swatchName): (BlobKind, String) = switch self {
        case .pink: (.round, "Pink")
        case .orange: (.round, "Orange")
        case .teal: (.boxy, "Teal")
        }
        let hex = BotLookCatalog.swatches.first { $0.name == swatchName }?.hex ?? BotLookCatalog.tealHex
        return BotAvatarSpec(
            name: "owner-intro-\(hex)",
            meta: BotAvatarMeta(
                shape: BotLookCatalog.shapeString(seed: "owner-intro-\(hex)", kind: kind), color: hex, custom: true, imageKind: .shape
            )
        )
    }
}
#endif
