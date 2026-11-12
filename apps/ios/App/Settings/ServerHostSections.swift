import PalBotProfile
import PalDesign
import SwiftUI

enum ServerHostCopy {
    static let unsupported = "This gateway does not support this yet."
    static let unknown = "Unknown"
}

struct ServerHealthSection: View {
    let host: HostServerModel

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption("Health", accessibilityIdentifier: "serverHealthCaption")
            switch host.health {
            case .loading:
                GroupedCard(accessibilityIdentifier: "serverHealthCard") {
                    LoadingRow(title: "Health", identifier: "serverHealthLoading")
                }
            case .unsupported:
                GroupedCard(accessibilityIdentifier: "serverHealthCard") {
                    SettingsRow.value("Health", value: "Not supported yet", accessibilityIdentifier: "serverHealthUnsupported")
                }
                CardFootnote(ServerHostCopy.unsupported, accessibilityIdentifier: "serverHealthFootnote")
            case .failed:
                FailureCard(
                    message: "Couldn't read this computer's health.", identifier: "serverHealthFailure",
                    retry: { Task { await host.loadHealth() } })
            case .loaded(let health):
                facts(health)
                checks(health)
            }
        }
    }

    private func facts(_ health: HostHealth) -> some View {
        GroupedCard(accessibilityIdentifier: "serverHealthCard") {
            SettingsRow.value("Version", value: version(health), accessibilityIdentifier: "serverHealthVersion")
            SettingsRow.value("Python", value: health.pythonVersion ?? ServerHostCopy.unknown, accessibilityIdentifier: "serverHealthPython")
            SettingsRow.value("System", value: health.platform ?? ServerHostCopy.unknown, accessibilityIdentifier: "serverHealthSystem")
            SettingsRow.value("Free disk space", value: disk(health), accessibilityIdentifier: "serverHealthDisk")
            SettingsRow.value("Computer uptime", value: uptime(health.hostUptimeSeconds), accessibilityIdentifier: "serverHealthUptime")
            SettingsRow.value("Profiles", value: count(health.profileCount), accessibilityIdentifier: "serverHealthProfiles")
            SettingsRow.value("Running gateways", value: count(health.runningGatewayCount), accessibilityIdentifier: "serverHealthGateways")
        }
    }

    private func checks(_ health: HostHealth) -> some View {
        GroupedCard(accessibilityIdentifier: "serverHealthChecksCard") {
            if !health.doctorRan {
                SettingsRow.value("Checks", value: "Couldn't run", accessibilityIdentifier: "serverHealthChecks")
            } else if health.problems.isEmpty {
                SettingsRow.value("Checks", value: "No problems found", accessibilityIdentifier: "serverHealthChecks")
            } else {
                ForEach(Array(health.problems.enumerated()), id: \.offset) { index, problem in
                    SettingsRow(
                        title: problem.severity == .error ? "Needs attention" : "Warning", subtitle: problem.message,
                        accessibilityIdentifier: "serverHealthProblem\(index)")
                }
            }
        }
    }

    private func version(_ health: HostHealth) -> String {
        switch (health.version, health.commit) {
        case (let version?, let commit?): "\(version) (\(commit.prefix(7)))"
        case (let version?, nil): version
        case (nil, let commit?): String(commit.prefix(7))
        case (nil, nil): ServerHostCopy.unknown
        }
    }

    private func disk(_ health: HostHealth) -> String {
        guard let free = health.diskFreeBytes else { return ServerHostCopy.unknown }
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        guard let total = health.diskTotalBytes else { return freeText }
        return "\(freeText) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private func uptime(_ seconds: Int64?) -> String {
        guard let seconds else { return ServerHostCopy.unknown }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(max(seconds, 60))) ?? ServerHostCopy.unknown
    }

    private func count(_ value: Int?) -> String {
        value.map(String.init) ?? ServerHostCopy.unknown
    }
}

struct ServerLogSection: View {
    let host: HostServerModel

    @Environment(\.hermesTheme) private var theme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption("Log", accessibilityIdentifier: "serverLogCaption")
            GroupedCard(accessibilityIdentifier: "serverLogPickerCard") {
                Picker(
                    "Log",
                    selection: Binding(get: { host.logName }, set: { name in Task { await host.selectLog(name) } })
                ) {
                    ForEach(HostLogName.allCases) { name in Text(name.title).tag(name) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, PalMetrics.rowInset)
                .frame(minHeight: PalMetrics.rowMinimumHeight)
                .accessibilityIdentifier("serverLogPicker")
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch host.logState {
        case .loading:
            GroupedCard(accessibilityIdentifier: "serverLogCard") {
                LoadingRow(title: "Log", identifier: "serverLogLoading")
            }
        case .unsupported:
            GroupedCard(accessibilityIdentifier: "serverLogCard") {
                SettingsRow.value("Log", value: "Not supported yet", accessibilityIdentifier: "serverLogUnsupported")
            }
            CardFootnote(ServerHostCopy.unsupported, accessibilityIdentifier: "serverLogFootnote")
        case .failed:
            FailureCard(
                message: "Couldn't read the log.", identifier: "serverLogFailure",
                retry: { Task { await host.loadLogs() } })
        case .loaded(let page):
            GroupedCard(accessibilityIdentifier: "serverLogCard") {
                if !page.available {
                    SettingsRow.value("Log", value: "Nothing logged yet", accessibilityIdentifier: "serverLogEmpty")
                } else {
                    logText
                    if host.hasOlderLines {
                        SettingsRow(
                            title: host.isLoadingOlder ? "Loading…" : "Show older lines", trailing: .none,
                            accessibilityIdentifier: "serverLogOlder", action: { Task { await host.loadOlder() } }
                        )
                        .disabled(host.isLoadingOlder)
                    }
                }
                SettingsRow(
                    title: "Refresh", trailing: .none, accessibilityIdentifier: "serverLogRefresh",
                    action: { Task { await host.loadLogs() } })
                if page.available, !host.logLines.isEmpty {
                    SettingsRow(
                        title: copied ? "Copied" : "Copy log", trailing: .none, accessibilityIdentifier: "serverLogCopy",
                        action: copy)
                }
            }
            CardFootnote(
                "Secrets are hidden before the log leaves this computer.", accessibilityIdentifier: "serverLogFootnote")
        }
    }

    private var logText: some View {
        ScrollView {
            Text(host.logText)
                .hermesText(.rowSubtitle).monospaced()
                .foregroundStyle(Color(theme.palette.textPrimary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.rowInset)
                .padding(.vertical, PalMetrics.rowVerticalPadding)
        }
        .frame(maxHeight: 320)
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("serverLogText")
    }

    private func copy() {
        Pasteboard.string = host.logText
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
