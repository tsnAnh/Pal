import HermesChat
import HermesDesign
import HermesProtocol
import SwiftUI

struct ClarifyCard: View {
    let prompt: PendingPrompt
    let answer: (String) -> Void

    @State private var selection: Set<Int> = []

    @Environment(\.hermesTheme) private var theme

    private var isMulti: Bool { prompt.multiSelect == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Text(prompt.question ?? String(localized: "Question"))
                        .font(.headline)
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { answer("") } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(theme.palette.textSecondary))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Skip question"))
                    .accessibilityIdentifier("clarifySkip")
                }
                ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                    Button { tap(index, choice) } label: {
                        HStack(spacing: 14) {
                            Text(Self.letter(index))
                                .font(.footnote)
                                .foregroundStyle(Color(selection.contains(index) ? theme.palette.chipSelectedText : theme.palette.textSecondary))
                                .frame(width: 30, height: 30)
                                .background(
                                    Color(selection.contains(index) ? theme.palette.chipSelectedFill : theme.palette.circleButtonFill),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(theme.palette.circleButtonStroke), lineWidth: 1))
                            Text(choice)
                                .font(.body)
                                .foregroundStyle(Color(theme.palette.textPrimary))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(choice))
                    .accessibilityAddTraits(selection.contains(index) ? .isSelected : [])
                    .accessibilityIdentifier("clarifyChoice-\(index)")
                }
                if isMulti, !prompt.choices.isEmpty {
                    Button("Confirm and continue") { confirm() }
                        .buttonStyle(.glass)
                        .disabled(selection.isEmpty)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("clarifyConfirm")
                }
            }
            .padding(16)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(theme.palette.cardStroke), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clarifyCard")
            Text("Or answer in the chat below")
                .font(.footnote)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding(.leading, 6)
        }
    }

    private func tap(_ index: Int, _ choice: String) {
        if isMulti {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
        } else {
            answer(choice)
        }
    }

    private func confirm() {
        answer(selection.sorted().map { String($0 + 1) }.joined(separator: ","))
    }

    private static func letter(_ index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index % 26))))
    }
}

struct ApprovalCard: View {
    @Environment(\.hermesTheme) private var theme

    let prompt: PendingPrompt
    let choose: (String) -> Void

    private static func label(for choice: String) -> String {
        switch choice {
        case "once": String(localized: "Allow")
        case "session": String(localized: "Allow for this chat")
        case "always": String(localized: "Always allow")
        case "deny": String(localized: "Don't allow")
        default: choice
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs your OK")
                .font(.headline)
                .foregroundStyle(Color(theme.palette.textPrimary))
            Text("This could change or delete something. Allow it?")
                .font(.body)
                .foregroundStyle(Color(theme.palette.textPrimary))
            if prompt.description != nil || prompt.command != nil {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let description = prompt.description {
                            Text(description)
                                .font(.footnote)
                                .foregroundStyle(Color(theme.palette.textSecondary))
                        }
                        if let command = prompt.command {
                            Text(command)
                                .font(.footnote.monospaced())
                                .foregroundStyle(Color(theme.palette.textSecondary))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.subheadline)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .tint(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("approvalDetails")
            }
            ForEach(Array(prompt.choices.enumerated()), id: \.offset) { index, choice in
                Button(Self.label(for: choice)) { choose(choice) }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("approvalChoice-\(index)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(theme.palette.cardStroke), lineWidth: 1))
    }
}
