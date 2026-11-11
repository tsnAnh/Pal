#if os(macOS)
import PalDesign
import PalRoster
import SwiftUI

struct MacRenameBot: View {
    let bot: BotRow
    let roster: RosterModel
    let router: AppRouter

    @Environment(\.hermesTheme) private var theme
    @FocusState private var focused: Bool
    @State private var name: String
    @State private var isSaving = false
    @State private var failure: BotAdminError?

    init(bot: BotRow, roster: RosterModel, router: AppRouter) {
        self.bot = bot
        self.roster = roster
        self.router = router
        _name = State(initialValue: bot.displayName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !isSaving && !trimmed.isEmpty && trimmed.count <= BotAdmin.maximumTitleLength && trimmed != bot.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Rename Bot")
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .frame(height: 49)
                .accessibilityAddTraits(.isHeader)
            PalHairline(color: PalTokens.panelBorder)
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(PalTokens.textPrimary)
                    .focused($focused)
                    .onSubmit(save)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(PalTokens.fieldBorder, lineWidth: 1))
                    .accessibilityLabel(Text("Bot name"))
                    .accessibilityIdentifier("renameBotField")
                if let message = errorMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(theme.palette.destructive))
                        .accessibilityIdentifier("renameBotError")
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)
            Spacer(minLength: 0)
            PalHairline(color: PalTokens.panelBorder)
            footer
        }
        .task {
            for _ in 0..<10 where !focused {
                focused = true
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var errorMessage: LocalizedStringKey? {
        switch failure {
        case .invalidName: "Choose a name between 1 and 60 characters."
        case .permissionDenied: "This device isn't allowed to change bots."
        case .botNotFound: "That bot no longer exists."
        case .conflict: "Another device changed this bot at the same time. Try again."
        case nil: nil
        default: "Couldn't rename the bot. Try again."
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Spacer()
            Button("Cancel") { router.renamingBot = nil }
                .buttonStyle(.palPill(horizontalPadding: 14))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("renameBotCancel")
            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small) }
                    Text("Save")
                }
            }
            .buttonStyle(.palPill(
                horizontalPadding: 14,
                fill: canSave ? PalTokens.inverseFill : PalTokens.fieldBorder,
                textColor: canSave ? PalTokens.inverseText : PalTokens.textTertiary,
                disabledOpacity: 1
            ))
            .disabled(!canSave)
            .accessibilityIdentifier("renameBotSave")
        }
        .padding(.trailing, 11)
        .frame(height: 52)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                try await roster.rename(bot, to: trimmed)
                router.renamingBot = nil
            } catch is CancellationError {
            } catch {
                failure = BotAdminError.classify(error)
            }
        }
    }
}
#endif
