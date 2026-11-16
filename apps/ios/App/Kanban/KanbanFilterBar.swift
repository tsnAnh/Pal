import PalDesign
import PalKanban
import SwiftUI

struct KanbanFilterBar: View {
    @Binding var filter: KanbanFilter
    let layout: KanbanBoardLayout

    var body: some View {
        VStack(spacing: 8) {
            searchField
            ScrollView(.horizontal) {
                HStack(spacing: PalMetrics.chipSpacing) {
                    menu(String(localized: "State"), identifier: "kanbanFilterState", selection: $filter.column, options: KanbanColumn.allCases, label: \.title)
                    if layout.bots.count > 1 || filter.bot != nil {
                        menu(String(localized: "Bot"), identifier: "kanbanFilterBot", selection: $filter.bot, options: layout.bots, label: \.self)
                    }
                    if layout.projects.count > 1 || filter.project != nil {
                        menu(String(localized: "Project"), identifier: "kanbanFilterProject", selection: $filter.project, options: layout.projects, label: \.self)
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
            .contentMargins(.horizontal, 22, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(PalTokens.textSecondary)
                .accessibilityHidden(true)
            TextField("", text: $filter.text, prompt: Text("Search cards"))
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
        .frame(height: 34)
        .background(PalTokens.chipFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 22)
    }

    private func menu<Value: Hashable>(
        _ title: String, identifier: String, selection: Binding<Value?>, options: [Value], label: KeyPath<Value, String>
    ) -> some View {
        let isSet = selection.wrappedValue != nil
        return Menu {
            Picker(title, selection: selection) {
                Text("All").tag(Value?.none)
                ForEach(options, id: \.self) { option in
                    Text(option[keyPath: label]).tag(Value?.some(option))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.wrappedValue.map { $0[keyPath: label] } ?? title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .hermesText(.chip)
            .foregroundStyle(PalTokens.textPrimary)
            .padding(.horizontal, PalMetrics.chipHorizontalPadding)
            .frame(height: PalMetrics.chipHeight)
            .background(isSet ? PalTokens.selected : PalTokens.chipFill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }
}
