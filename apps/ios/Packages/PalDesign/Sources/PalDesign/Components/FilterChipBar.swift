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
            HStack(spacing: PalMetrics.chipSpacing) {
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
        FilterChip(title: item.title, isSelected: item.id == selection, accessibilityIdentifier: "\(accessibilityIdentifier)-\(item.id)") {
            selection = item.id
        }
    }
}

public struct FilterChipLabel: View {
    public let title: String
    public let isSelected: Bool
    public let trailingSymbol: String?

    @Environment(\.hermesTheme) private var theme

    public init(title: String, isSelected: Bool, trailingSymbol: String? = nil) {
        self.title = title
        self.isSelected = isSelected
        self.trailingSymbol = trailingSymbol
    }

    public var body: some View {
        let ink = Color(isSelected ? theme.palette.chipSelectedText : theme.palette.chipText)
        HStack(spacing: 6) {
            Text(title)
                .hermesText(.chip)
            if let trailingSymbol {
                PalIcon(trailingSymbol, ink: isSelected ? .onInverseFill : .primary)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, PalMetrics.chipHorizontalPadding)
        .frame(height: PalMetrics.chipHeight)
        .background(Color(isSelected ? theme.palette.chipSelectedFill : theme.palette.chipFill), in: Capsule())
        .contentShape(Capsule())
    }
}

public struct FilterChip: View {
    public let title: String
    public let isSelected: Bool
    public let accessibilityIdentifier: String
    public let action: () -> Void

    public init(title: String, isSelected: Bool, accessibilityIdentifier: String, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            FilterChipLabel(title: title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
