import SwiftUI

public struct GroupedCard<Content: View>: View {
    public let accessibilityIdentifier: String
    public let separatorInset: CGFloat
    private let content: Content

    @Environment(\.hermesTheme) private var theme

    public init(
        separatorInset: CGFloat = HermesMetrics.rowInset,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.separatorInset = separatorInset
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous)
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    rows[index]
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(Color(theme.palette.separator))
                            .frame(height: HermesMetrics.separatorThickness)
                            .padding(.leading, separatorInset)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .background(Color(theme.palette.groupedCard), in: shape)
        .overlay(shape.strokeBorder(Color(theme.palette.cardStroke), lineWidth: HermesMetrics.separatorThickness))
        .clipShape(shape)
        .padding(.horizontal, HermesMetrics.screenMargin)
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
            .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
