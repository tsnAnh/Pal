import HermesDesign
import SwiftUI

struct FindBar: View {
    @Bindable var model: ChatModel

    @Environment(\.hermesTheme) private var theme
    @FocusState private var fieldFocused: Bool

    private var countLabel: String {
        if model.findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if model.findMatches.isEmpty { return String(localized: "No results") }
        return String(localized: "\(model.findPosition + 1) of \(model.findMatches.count)")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityHidden(true)
            TextField("", text: $model.findQuery, prompt: Text("Find in Chat").foregroundStyle(Color(theme.palette.textTertiary)))
                .hermesText(.composerField)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .neverAutocapitalized()
                .onSubmit { model.findPrevious() }
                .accessibilityLabel(Text("Find in Chat"))
                .accessibilityIdentifier("findField")
            Text(countLabel)
                .hermesText(.chip)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("findCount")
            stepButton("chevron.up", label: "Previous match", id: "findPrevious") { model.findPrevious() }
            stepButton("chevron.down", label: "Next match", id: "findNext") { model.findNext() }
            Button { model.endFinding() } label: {
                Text("Done")
                    .hermesText(.pill)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("findDone")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: ChatMetrics.composerHeight)
        .background(PalTokens.elevated, in: Capsule())
        .overlay(Capsule().strokeBorder(PalTokens.panelBorder, lineWidth: 1))
        .padding(.horizontal, ChatMetrics.edgeMargin)
        .padding(.vertical, 8)
        .onAppear { fieldFocused = true }
    }

    private func stepButton(_ systemName: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.findMatches.isEmpty)
        .opacity(model.findMatches.isEmpty ? 0.35 : 1)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}
