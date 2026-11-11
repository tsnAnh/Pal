import PalDesign
import PalSettings
import Observation
import SwiftUI

@MainActor
@Observable
final class PermissionsModel {
    private(set) var state: Loadable<PermissionsSummary> = .loading
    private(set) var isBusy = false
    var actionFailure: String?

    func load(hub: SettingsHub) async {
        do {
            let summary = PermissionsSummary(try await hub.api.permissions())
            state = .loaded(summary)
            hub.updatePermissions(summary)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(SettingsFailure(error).message)
        }
    }

    func setAutoReview(_ enabled: Bool, hub: SettingsHub) async {
        await mutate(hub: hub) { _ = try await $0.setAutoReview(enabled) }
    }

    func add(_ text: String, to list: PermissionList, hub: SettingsHub) async -> Bool {
        await mutate(hub: hub) { _ = try await $0.addRule(list, text: text) }
    }

    func remove(_ rule: PermissionRuleEntry, hub: SettingsHub) async {
        await mutate(hub: hub) { try await $0.removeRule(id: rule.id) }
    }

    @discardableResult
    private func mutate(hub: SettingsHub, _ change: (SettingsAPI) async throws -> Void) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await change(hub.api)
            await load(hub: hub)
            return true
        } catch {
            actionFailure = SettingsFailure(error).message
            await load(hub: hub)
            return false
        }
    }
}

struct PermissionsScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model = PermissionsModel()
    @State private var addingTo: PermissionList?
    @State private var removing: PermissionRuleEntry?

    var body: some View {
        SettingsPage(title: "Permissions", identifier: "permissionsScreen", back: back) {
            switch model.state {
            case .loading:
                GroupedCard(accessibilityIdentifier: "permissionsLoading") {
                    LoadingRow(title: "Permissions", identifier: "permissionsLoadingRow")
                }
            case .failed(let message):
                FailureCard(message: message, identifier: "permissionsFailure") { Task { await model.load(hub: hub) } }
            case .loaded(let summary):
                content(summary)
            }
        }
        .task { await model.load(hub: hub) }
        .sheet(item: $addingTo) { list in
            AddRuleSheet(list: list, model: model, hub: hub) { addingTo = nil }
                .presentationDetents([.medium])
                .macSheetFrame()
        }
        .confirmationDialog(
            "Remove this rule?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let rule = removing { Task { await model.remove(rule, hub: hub) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.text ?? "")
        }
        .alert("Permissions", isPresented: Binding(get: { model.actionFailure != nil }, set: { if !$0 { model.actionFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionFailure ?? "")
        }
    }

    @ViewBuilder
    private func content(_ summary: PermissionsSummary) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            GroupedCard(accessibilityIdentifier: "permissionsAutoReviewCard") {
                SettingsRow.toggle(
                    "Auto-Review", subtitle: "Review your Bots' actions based on custom rules",
                    isOn: Binding(
                        get: { summary.autoReview },
                        set: { enabled in
                            SettingsHaptics.selection()
                            Task { await model.setAutoReview(enabled, hub: hub) }
                        }
                    ),
                    accessibilityIdentifier: "permissionsAutoReviewToggle"
                )
            }
            if summary.approvalsAreOff {
                CardFootnote(
                    "Approvals are turned off for this Bot, so rules are saved but not applied.",
                    accessibilityIdentifier: "permissionsApprovalsOff"
                )
            }
        }
        ruleSection(
            .ask, title: "Always Ask", subtitle: "Stop and ask when an action matches these rules", rules: summary.ask
        )
        ruleSection(
            .allow, title: "Allow without Asking", subtitle: "Continue automatically when an action matches these rules",
            rules: summary.allow
        )
    }

    private func ruleSection(_ list: PermissionList, title: String, subtitle: String, rules: [PermissionRuleEntry]) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionHeader(title, subtitle: subtitle, accessibilityIdentifier: "permissionsHeader-\(list.rawValue)") {
                Button("Add Rule") { addingTo = list }
                    .buttonStyle(.pill())
                    .padding(.trailing, 1)
                    .accessibilityIdentifier("permissionsAddRule-\(list.rawValue)")
            }
            GroupedCard(accessibilityIdentifier: "permissionsRules-\(list.rawValue)") {
                if rules.isEmpty {
                    PlaceholderRow("No rules yet", accessibilityIdentifier: "permissionsNoRules-\(list.rawValue)")
                } else {
                    ForEach(rules) { rule in
                        SettingsRow(
                            title: rule.text, trailing: .none, accessibilityIdentifier: "permissionsRule-\(rule.id)",
                            action: { removing = rule }
                        )
                    }
                }
            }
        }
    }
}

struct AddRuleSheet: View {
    let list: PermissionList
    let model: PermissionsModel
    let hub: SettingsHub
    let close: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.hermesTheme) private var theme

    private static let limit = 280

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmed.isEmpty && trimmed.count <= Self.limit }

    var body: some View {
        SheetChrome(
            title: list == .ask ? "Always Ask" : "Allow without Asking", accessibilityIdentifier: "permissionsAddSheet",
            onLeading: close,
            trailing: {
                PillButton(
                    "Add", kind: isValid ? .accent : .dimmed, isBusy: model.isBusy, accessibilityIdentifier: "permissionsSaveRule"
                ) {
                    Task { if await model.add(trimmed, to: list, hub: hub) { close() } }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    GroupedCard(accessibilityIdentifier: "permissionsRuleField") {
                        TextField("Describe the action in a sentence", text: $text, axis: .vertical)
                            .lineLimit(3...6)
                            .focused($focused)
                            .hermesText(.rowTitle)
                            .foregroundStyle(Color(theme.palette.textPrimary))
                            .padding(.horizontal, PalMetrics.rowInset)
                            .padding(.vertical, 14)
                            .accessibilityIdentifier("permissionsRuleText")
                    }
                    CardFootnote("\(trimmed.count) of \(Self.limit)", accessibilityIdentifier: "permissionsRuleCount")
                }
                .onAppear { focused = true }
            }
        )
    }
}
