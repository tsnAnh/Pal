import PalConnect
import PalDesign
import PalProtocol
import SwiftUI

struct ConnectorToolsCard: View {
    @Bindable var model: ConnectorDetailsModel

    var body: some View {
        switch model.load {
        case .loading:
            section { loadingCard }
        case .failed:
            section { failedCard }
        case .ready:
            let sections = model.toolSections
            if !sections.isEmpty {
                section {
                    ConnectorDetailsCard {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { ConnectorDetailsDivider() }
                            groupBlock(group)
                        }
                    }
                }
                if ConnectorDetailsLayout.showsWritesFootnote(sections) {
                    ConnectorDetailsFootnote(text: ConnectorDetailsLayout.writesFootnote, identifier: "connectorDetailsToolsFootnote")
                }
            }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ConnectorDetailsSection(title: String(localized: "Tool permissions"), identifier: "connectorDetailsTools", content: content)
    }

    private var loadingCard: some View {
        ConnectorDetailsCard {
            ForEach(0..<3, id: \.self) { index in
                if index > 0 { ConnectorDetailsDivider() }
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(PalTokens.control)
                        .frame(height: 14)
                }
                .padding(.horizontal, PalMetrics.screenMargin)
                .frame(minHeight: 52)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading tools"))
        .accessibilityIdentifier("connectorDetailsToolsLoading")
    }

    private var failedCard: some View {
        ConnectorDetailsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't load the tools")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PalTokens.textPrimary)
                Text("Your accounts are fine. Try again in a moment.")
                    .font(.system(size: 14))
                    .foregroundStyle(PalTokens.textSecondary)
                    .padding(.bottom, 6)
                Button("Try again") { Task { await model.refresh() } }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("connectorDetailsToolsRetry")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PalMetrics.screenMargin)
        }
        .accessibilityIdentifier("connectorDetailsToolsFailed")
    }

    @ViewBuilder
    private func groupBlock(_ group: ConnectorToolSection) -> some View {
        let open = model.expanded.contains(group.group)
        groupRow(group, open: open)
        if open {
            let showingAll = model.showingAll.contains(group.group)
            ForEach(ConnectorDetailsLayout.visible(group.tools, showingAll: showingAll)) { tool in
                toolRow(tool, group: group)
            }
            if !showingAll, ConnectorDetailsLayout.hasMore(group.tools) {
                Button { model.showAll(group.group) } label: {
                    Text("Show all \(group.count)")
                        .font(.system(size: 14))
                        .foregroundStyle(PalTokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 44)
                        .padding(.trailing, PalMetrics.screenMargin)
                        .padding(.top, 12)
                        .padding(.bottom, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectorToolsShowAll-\(group.group.rawValue)")
            }
        }
    }

    private func groupRow(_ group: ConnectorToolSection, open: Bool) -> some View {
        HStack(spacing: 10) {
            Button { model.toggle(group.group) } label: {
                HStack(spacing: 10) {
                    PalIcon(open ? "chevron.down" : "chevron.right", ink: .secondary)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14)
                    Text(group.title)
                        .font(.system(size: 16))
                        .foregroundStyle(PalTokens.textPrimary)
                    Text("\(group.count)")
                        .font(.system(size: 13))
                        .foregroundStyle(PalTokens.textTertiary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(group.title), \(group.count)"))
            .accessibilityValue(Text(open ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("connectorToolsGroup-\(group.group.rawValue)")
            policy(group)
        }
        .padding(.horizontal, PalMetrics.screenMargin)
    }

    @ViewBuilder
    private func policy(_ group: ConnectorToolSection) -> some View {
        if group.isFixed {
            fixedLabel.accessibilityIdentifier("connectorToolsPolicy-\(group.group.rawValue)")
        } else if let mode = group.mode {
            Menu {
                ForEach(group.options, id: \.self) { option in
                    Button { Task { await model.setPolicy(group.group, to: option) } } label: {
                        if option == mode {
                            Label(option.title, palIcon: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                    .accessibilityIdentifier("connectorToolsPolicy-\(group.group.rawValue)-\(option.rawValue)")
                }
            } label: {
                HStack(spacing: 5) {
                    Text(mode.title)
                    PalIcon("chevron.down", ink: .secondary).font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 15))
                .foregroundStyle(PalTokens.textSecondary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(model.policyBusy.contains(group.group))
            .accessibilityLabel(Text("\(group.title) permission"))
            .accessibilityValue(Text(mode.title))
            .accessibilityIdentifier("connectorToolsPolicy-\(group.group.rawValue)")
        }
    }

    private var fixedLabel: some View {
        HStack(spacing: 5) {
            PalIcon("lock", ink: .tertiary).font(.system(size: 12))
            Text("Never")
        }
        .font(.system(size: 15))
        .foregroundStyle(PalTokens.textTertiary)
    }

    private func toolRow(_ tool: ConnectorDetailTool, group: ConnectorToolSection) -> some View {
        HStack(spacing: 10) {
            Text(tool.title)
                .font(.system(size: 16))
                .foregroundStyle(group.isFixed ? PalTokens.textSecondary : PalTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if group.isFixed {
                fixedLabel
            } else if let mode = group.mode {
                Text(mode.title)
                    .font(.system(size: 15))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 44)
        .padding(.trailing, PalMetrics.screenMargin)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectorTool-\(tool.name)")
    }
}
