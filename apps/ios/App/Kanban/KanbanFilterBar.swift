import PalDesign
import PalKanban
import SwiftUI

struct KanbanFilterBar: View {
    @Binding var filter: KanbanFilter
    let layout: KanbanBoardLayout
    let boardName: String
    let compact: Bool

    @Environment(\.kanbanRoster) private var roster

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    heading
                    searchField
                    chips
                }
                .padding(12)
            } else {
                HStack(spacing: 12) {
                    heading
                    chips
                    searchField.frame(width: 220)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 48)
            }
        }
        .kanbanGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, 10)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(KanbanPresentation.surfaceTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PalTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("kanbanTitle")
            Text(boardName)
                .hermesText(.chip)
                .foregroundStyle(PalTokens.textSecondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if layout.bots.count > 1 || filter.bot != nil {
                    botChip(nil)
                    ForEach(roster.names.sorted(layout.bots), id: \.self) { botChip($0) }
                }
                menu(String(localized: "State"), identifier: "kanbanFilterState", selection: $filter.column, options: KanbanColumn.allCases) { $0.title }
                if layout.projects.count > 1 || filter.project != nil {
                    menu(String(localized: "Project"), identifier: "kanbanFilterProject", selection: $filter.project, options: layout.projects) { $0 }
                }
                if filter.isActive {
                    Button(String(localized: "Clear")) { filter = KanbanFilter() }
                        .buttonStyle(.plain)
                        .hermesText(.chip)
                        .foregroundStyle(PalTokens.textSecondary)
                        .accessibilityIdentifier("kanbanFilterClear")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func botChip(_ handle: String?) -> some View {
        let isSet = filter.bot == handle
        return Button { filter.bot = handle } label: {
            HStack(spacing: 6) {
                if let handle {
                    BotAvatarView(spec: roster.spec(handle), size: 18, animated: false)
                        .frame(width: 18, height: 18)
                }
                Text(handle.flatMap { roster.names.name(for: $0) } ?? String(localized: "All bots")).lineLimit(1)
            }
            .hermesText(.chip)
            .foregroundStyle(isSet ? PalTokens.inverseText : PalTokens.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isSet ? PalTokens.inverseFill : PalTokens.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSet ? .isSelected : [])
        .accessibilityIdentifier("kanbanFilterBot-\(handle ?? "all")")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityHidden(true)
            TextField("", text: $filter.text, prompt: Text("Search cards").foregroundStyle(PalTokens.textSecondary))
                .textFieldStyle(.plain)
                .hermesText(.chip)
                .foregroundStyle(PalTokens.textPrimary)
                .autocorrectionDisabled()
                .accessibilityLabel(Text("Search cards"))
                .accessibilityIdentifier("kanbanSearch")
            if !filter.text.isEmpty {
                Button { filter.text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(PalTokens.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
                .accessibilityIdentifier("kanbanSearch-clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(PalTokens.chipFill, in: Capsule())
    }

    private func menu<Value: Hashable>(
        _ title: String, identifier: String, selection: Binding<Value?>, options: [Value], label: @escaping (Value) -> String
    ) -> some View {
        let isSet = selection.wrappedValue != nil
        return Menu {
            Picker(title, selection: selection) {
                Text("All").tag(Value?.none)
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(Value?.some(option))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.map(label) ?? title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .hermesText(.chip)
            .foregroundStyle(PalTokens.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isSet ? PalTokens.selected : PalTokens.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }
}
