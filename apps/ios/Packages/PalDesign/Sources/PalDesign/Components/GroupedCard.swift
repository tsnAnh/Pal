import SwiftUI

public struct GroupedCard<Content: View>: View {
    public let accessibilityIdentifier: String
    private let content: Content

    @Environment(\.hermesTheme) private var theme

    public init(
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
        VStack(spacing: 0) { content }
            .padding(.vertical, 6)
            .background(Color(theme.palette.groupedCard), in: shape)
            .overlay(shape.strokeBorder(Color(theme.palette.cardStroke), lineWidth: PalMetrics.separatorThickness))
            .clipShape(shape)
            .padding(.horizontal, PalMetrics.screenMargin)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

public struct SectionCaption: View {
    public let text: String
    public let accessibilityIdentifier: String

    @Environment(\.hermesTheme) private var theme

    public init(_ text: String, accessibilityIdentifier: String) {
        self.text = text
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        Text(text)
            .hermesText(.sectionCaption)
            .foregroundStyle(Color(theme.palette.sectionCaption))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
