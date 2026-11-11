import PalDesign
import SwiftUI

struct RichCardFrame<Accessory: View, Content: View>: View {
    let title: String
    let copyText: String
    let identifier: String
    let accessory: Accessory
    let content: Content

    @State private var copied = false

    init(
        title: String,
        copyText: String,
        identifier: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.copyText = copyText
        self.identifier = identifier
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .hermesText(.chip)
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                accessory
                Button {
                    Pasteboard.string = copyText
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(PalTokens.textSecondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy")))
                .accessibilityIdentifier("copyCode")
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            content
        }
        .background(PalTokens.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

extension RichCardFrame where Accessory == EmptyView {
    init(title: String, copyText: String, identifier: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, copyText: copyText, identifier: identifier, accessory: { EmptyView() }, content: content)
    }
}

struct CodeCardView: View {
    let source: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        guard let language, !language.isEmpty else { return String(localized: "Code") }
        return language
    }

    var body: some View {
        RichCardFrame(title: title, copyText: source, identifier: "codeCard") {
            ExpandableBlock(lineCount: RichCode.lineCount(source)) {
                Text(RichRendering.code(source, language: language, scheme: colorScheme))
                    .hermesText(.chatCode)
                    .font(RichCode.font)
                    .foregroundStyle(PalTokens.textPrimary)
                    .textSelection(.enabled)
            }
        }
    }
}
