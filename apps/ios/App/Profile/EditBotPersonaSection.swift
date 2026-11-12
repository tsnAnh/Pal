import PalBotProfile
import PalDesign
import SwiftUI

struct EditBotPersonaSection: View {
    @Bindable var model: EditBotModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(String(localized: "What this bot is good at"), accessibilityIdentifier: "editBotDescriptionCaption")
            field(identifier: "editBotDescription") {
                TextField("", text: $model.bio, prompt: Text("A short line about what it does"), axis: .vertical)
                    .lineLimit(1...4)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, 14)
                    .disabled(!model.personaFieldsEnabled)
                    .accessibilityLabel(Text("What this bot is good at"))
            }
            HStack(spacing: 8) {
                Button { Task { await model.writeDescription() } } label: {
                    HStack(spacing: 6) {
                        if model.isWritingDescription { ProgressView().controlSize(.small) }
                        Text("Write one for me")
                    }
                }
                .buttonStyle(.pill())
                .disabled(!model.personaFieldsEnabled || model.isWritingDescription)
                .accessibilityIdentifier("editBotWriteDescription")
                if model.offersReplaceDescription {
                    Button("Replace it") { model.confirmsReplaceDescription = true }
                        .buttonStyle(.pill())
                        .disabled(model.isWritingDescription)
                        .accessibilityIdentifier("editBotReplaceDescription")
                }
            }
            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
            if model.isBioTooLong {
                note(String(localized: "Keep it under \(BotPersona.maximumDescriptionLength) characters."), identifier: "editBotDescriptionLimit")
            }
            if let message = model.describeFailure {
                note(message, identifier: "editBotDescribeFailure")
            }
            SectionCaption(String(localized: "Personality"), accessibilityIdentifier: "editBotPersonalityCaption")
                .padding(.top, 8)
            field(identifier: "editBotPersonality") {
                TextEditor(text: $model.soul)
                    .scrollContentBackground(.hidden)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .frame(minHeight: 140)
                    .padding(.horizontal, PalMetrics.rowInset - 5)
                    .padding(.vertical, 8)
                    .disabled(!model.personaFieldsEnabled)
                    .accessibilityLabel(Text("Personality"))
            }
            if model.isSoulInvalid {
                note(String(localized: "Write a personality of up to \(BotPersona.maximumSoulLength) characters."), identifier: "editBotPersonalityLimit")
            }
            switch model.personaState {
            case .loading:
                note(String(localized: "Loading…"), identifier: "editBotPersonaLoading", destructive: false)
            case .failed:
                HStack(spacing: 8) {
                    note(String(localized: "Couldn't load the description and personality."), identifier: "editBotPersonaFailed")
                    Button("Try again") { Task { await model.loadPersona() } }
                        .buttonStyle(.pill())
                        .accessibilityIdentifier("editBotPersonaRetry")
                }
            case .ready:
                EmptyView()
            }
        }
        .opacity(model.personaState == .ready ? 1 : 0.6)
        .confirmationDialog(
            Text("Replace the description?"),
            isPresented: $model.confirmsReplaceDescription,
            titleVisibility: .visible
        ) {
            Button("Replace") { Task { await model.writeDescription(overwrite: true) } }
                .accessibilityIdentifier("editBotReplaceDescriptionConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pal writes a new one and the description you wrote is lost.")
        }
        .task { await model.loadPersona() }
    }

    private func field<Content: View>(identifier: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, PalMetrics.screenMargin)
            .accessibilityIdentifier(identifier)
    }

    private func note(_ text: String, identifier: String, destructive: Bool = true) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(destructive ? Color(theme.palette.destructive) : Color(theme.palette.sectionCaption))
            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
            .accessibilityIdentifier(identifier)
    }
}
