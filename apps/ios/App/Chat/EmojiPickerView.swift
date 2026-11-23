import PalChat
import PalDesign
import SwiftUI

struct EmojiPickerView: View {
    let selected: String?
    let ink: Color
    let columns: Int
    let pick: (String) -> Void

    @State private var query = ""

    private var results: [ReactionEmoji] { ReactionCatalog.search(query) }

    var body: some View {
        VStack(spacing: 8) {
            PalTextField(String(localized: "Search emoji"), text: $query)
                .font(.system(size: MessageMenuMetrics.textSize))
                .padding(.horizontal, 10)
                .frame(height: PlatformVariant.pick(mac: 28, iOS: 36))
                .accessibilityIdentifier("emojiSearch")
            if results.isEmpty {
                Text("No emoji found")
                    .font(.system(size: MessageMenuMetrics.textSize))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                        ForEach(results) { entry in cell(entry.symbol) }
                    }
                }
                .frame(maxHeight: PlatformVariant.pick(mac: 190, iOS: 260))
            }
        }
        .accessibilityIdentifier("emojiPicker")
    }

    private func cell(_ emoji: String) -> some View {
        Button { pick(emoji) } label: {
            Text(emoji)
                .font(.system(size: MessageMenuMetrics.emojiSize))
                .frame(maxWidth: .infinity, minHeight: PlatformVariant.pick(mac: 30, iOS: 40))
                .overlay {
                    if selected == emoji {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ink, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(emoji))
        .accessibilityIdentifier("emojiPick-\(emoji)")
    }
}
