import SwiftUI

public struct FilterChipItem<ID: Hashable & Sendable>: Identifiable, Sendable {
    public let id: ID
    public let title: String

    public init(id: ID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct FilterChipBar<ID: Hashable & Sendable>: View {
    public let items: [FilterChipItem<ID>]
    @Binding public var selection: ID
    public let accessibilityIdentifier: String

    @Environment(\.hermesTheme) private var theme

    public init(items: [FilterChipItem<ID>], selection: Binding<ID>, accessibilityIdentifier: String) {
        self.items = items
        _selection = selection
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HermesMetrics.chipSpacing) {
                ForEach(items) { item in
                    chip(item)
                }
            }
        }
        .contentMargins(.horizontal, 22, for: .scrollContent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func chip(_ item: FilterChipItem<ID>) -> some View {
        let isSelected = item.id == selection
        return Button { selection = item.id } label: {
            Text(item.title)
                .hermesText(.chip)
                .foregroundStyle(Color(isSelected ? theme.palette.chipSelectedText : theme.palette.chipText))
                .padding(.horizontal, HermesMetrics.chipHorizontalPadding)
                .frame(height: HermesMetrics.chipHeight)
                .background(Color(isSelected ? theme.palette.chipSelectedFill : theme.palette.chipFill), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityIdentifier)-\(item.id)")
    }
}
