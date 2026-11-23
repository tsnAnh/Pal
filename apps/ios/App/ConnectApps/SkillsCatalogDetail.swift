import PalConnect
import PalDesign
import SwiftUI

extension SkillsCatalogSheet {
    func detailPage(_ row: SkillRow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                outcomeBanner.padding(.horizontal, -ConnectRowMetrics.horizontalMargin)
                detailHeader(row)
                detailContent(row)
                detailActions(row)
            }
            .padding(.horizontal, ConnectRowMetrics.horizontalMargin)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: row.id) { await model.loadDetail() }
        .accessibilityIdentifier("skillDetail")
    }

    private func detailHeader(_ row: SkillRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stateTitle(row.state))
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("skillDetailState")
            if case .loaded(let detail) = model.detailPhase, !detail.summary.isEmpty {
                Text(detail.summary).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            } else if !row.summary.isEmpty {
                Text(row.summary).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            }
        }
    }

    private func stateTitle(_ state: SkillState) -> String {
        switch state {
        case .available: String(localized: "Not installed")
        case .installed: String(localized: "Installed")
        case .updateAvailable: String(localized: "Update available")
        }
    }

    @ViewBuilder
    private func detailContent(_ row: SkillRow) -> some View {
        switch model.detailPhase {
        case .loading:
            DelayedProgressView()
                .tint(Color(theme.palette.textSecondary))
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .accessibilityIdentifier("skillDetailLoading")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message).hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textSecondary))
                Button("Try again") { Task { await model.loadDetail() } }
                    .glassButtonStyle()
                    .accessibilityIdentifier("skillDetailRetry")
            }
            .accessibilityIdentifier("skillDetailFailed")
            sourceBlock(source: row.source, identifier: row.installTarget, trust: row.trust)
        case .loaded(let detail):
            sourceBlock(source: detail.source ?? row.source, identifier: detail.identifier ?? row.identifier, trust: row.trust)
            if !detail.tags.isEmpty {
                Text(detail.tags.joined(separator: ", "))
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            requirementsBlock(detail.requirements, row: row)
        }
    }

    private func sourceBlock(source: String?, identifier: String?, trust: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source").hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            let parts = [source, trust].compactMap { $0 }.joined(separator: " · ")
            if !parts.isEmpty {
                Text(parts).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
            }
            if let identifier {
                Text(identifier)
                    .hermesText(.rowSubtitle).monospaced()
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("skillDetailSource")
    }

    private func requirementsBlock(_ requirements: SkillRequirements, row: SkillRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requirements").hermesText(.rowTitle).foregroundStyle(Color(theme.palette.textPrimary))
            if requirements.isEmpty {
                Text("No extra setup needed.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            ForEach(requirements.environment) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.name)
                        .hermesText(.rowSubtitle).monospaced()
                        .foregroundStyle(Color(theme.palette.chipText))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(theme.palette.chipFill), in: Capsule())
                    let note = [key.prompt, key.isOptional ? String(localized: "Optional") : nil].compactMap { $0 }.joined(separator: " · ")
                    if !note.isEmpty {
                        Text(note).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
                    }
                    if let help = key.help {
                        Text(help).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
                    }
                    if !key.isOptional, row.isInstalled {
                        Button(String(localized: "Add key")) { model.beginKeyEntry(row, keyName: key.name) }
                            .glassButtonStyle()
                            .accessibilityLabel(Text("Add key for \(key.name)"))
                            .accessibilityIdentifier("skillAddKey-\(key.name)")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("skillRequirement-\(key.name)")
            }
            if requirements.needsSecrets, !row.isInstalled {
                Text("Install this skill to add the keys \(botName) needs to use it.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("skillRequirementsNote")
            }
            if !requirements.commands.isEmpty {
                Text("Needs these tools installed on \(botName)'s computer: \(requirements.commands.joined(separator: ", "))")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("skillRequirementCommands")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailActions(_ row: SkillRow) -> some View {
        let working = model.isWorking(on: row)
        VStack(spacing: 10) {
            switch row.state {
            case .available:
                busyButton(String(localized: "Install"), isBusy: working, identifier: "skillInstall") { Task { await model.install(row) } }
                    .glassButtonStyle(prominent: true)
            case .updateAvailable where row.isRemovable:
                busyButton(String(localized: "Update"), isBusy: working, identifier: "skillUpdate") { Task { await model.update(row) } }
                    .glassButtonStyle(prominent: true)
                removeButton(row, working: working)
            case .installed where row.isRemovable, .updateAvailable:
                removeButton(row, working: working)
            case .installed:
                Text("Built in. It can't be removed from here.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
        }
        .disabled(model.isMutating && !working)
    }

    @ViewBuilder
    private func removeButton(_ row: SkillRow, working: Bool) -> some View {
        if row.isRemovable {
            busyButton(String(localized: "Remove"), isBusy: working, identifier: "skillRemove") { model.removeTarget = row }
                .glassButtonStyle()
        }
    }

    private func busyButton(_ title: String, isBusy: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy { ProgressView().controlSize(.small) }
                Text(title)
            }
        }
        .disabled(isBusy)
        .accessibilityIdentifier(identifier)
    }
}
