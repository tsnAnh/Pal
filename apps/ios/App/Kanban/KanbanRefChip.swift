import PalDesign
import SwiftUI

struct KanbanRefChip: View {
    let ref: String

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Text(ref)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(PalTokens.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(PalTokens.chipFill, in: Capsule())
                .accessibilityIdentifier("kanbanRef")
            Button(action: copy) {
                Text(copied ? String(localized: "Copied") : String(localized: "Copy"))
            }
            .buttonStyle(.palGlass)
            .accessibilityIdentifier("kanbanRefCopy")
        }
        .onDisappear { reset?.cancel() }
    }

    private func copy() {
        Pasteboard.string = ref
        copied = true
        reset?.cancel()
        reset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
