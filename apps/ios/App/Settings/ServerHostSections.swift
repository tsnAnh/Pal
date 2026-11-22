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
            SettingsCaption("Health", identifier: "serverHealthCaption")
            switch host.health {
            case .loading:
                SettingsCard(identifier: "serverHealthCard") {
                    LoadingRow(title: "Health", identifier: "serverHealthLoading")
                }
            case .unsupported:
                SettingsCard(identifier: "serverHealthCard") {
                    SettingsValueRow("Health", value: "Not supported yet", identifier: "serverHealthUnsupported")
                }
                SettingsFootnote(ServerHostCopy.unsupported, identifier: "serverHealthFootnote")
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
        SettingsCard(identifier: "serverHealthCard") {
            SettingsValueRow("Version", value: version(health), identifier: "serverHealthVersion")
            SettingsValueRow("Python", value: health.pythonVersion ?? ServerHostCopy.unknown, identifier: "serverHealthPython")
            SettingsValueRow("System", value: health.platform ?? ServerHostCopy.unknown, identifier: "serverHealthSystem")
            SettingsValueRow("Free disk space", value: disk(health), identifier: "serverHealthDisk")
            SettingsValueRow("Computer uptime", value: uptime(health.hostUptimeSeconds), identifier: "serverHealthUptime")
            SettingsValueRow("Profiles", value: count(health.profileCount), identifier: "serverHealthProfiles")
            SettingsValueRow("Running gateways", value: count(health.runningGatewayCount), identifier: "serverHealthGateways")
        }
    }

    private func checks(_ health: HostHealth) -> some View {
        SettingsCard(identifier: "serverHealthChecksCard") {
            if !health.doctorRan {
                SettingsValueRow("Checks", value: "Couldn't run", identifier: "serverHealthChecks")
            } else if health.problems.isEmpty {
                SettingsValueRow("Checks", value: "No problems found", identifier: "serverHealthChecks")
            } else {
                ForEach(Array(health.problems.enumerated()), id: \.offset) { index, problem in
                    SettingsValueRow(
                        problem.severity == .error ? "Needs attention" : "Warning", value: nil, subtitle: problem.message,
                        identifier: "serverHealthProblem\(index)")
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
            SettingsCaption("Log", identifier: "serverLogCaption")
            SettingsCard(identifier: "serverLogPickerCard") { logPicker }
            content
        }
    }

    private var logSelection: Binding<HostLogName> {
        Binding(get: { host.logName }, set: { name in Task { await host.selectLog(name) } })
    }

    @ViewBuilder
    private var logPicker: some View {
        #if os(macOS)
        MacRow(title: String(localized: "Log"), identifier: "serverLogPickerRow") {
            MacMenuValue(current: host.logName.title, selection: logSelection, identifier: "serverLogPicker") {
                ForEach(HostLogName.allCases) { name in Text(name.title).tag(name) }
            }
        }
        #else
        Picker("Log", selection: logSelection) {
            ForEach(HostLogName.allCases) { name in Text(name.title).tag(name) }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, PalMetrics.rowInset)
        .frame(minHeight: PalMetrics.rowMinimumHeight)
        .accessibilityIdentifier("serverLogPicker")
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch host.logState {
        case .loading:
            SettingsCard(identifier: "serverLogCard") {
                LoadingRow(title: "Log", identifier: "serverLogLoading")
            }
        case .unsupported:
            SettingsCard(identifier: "serverLogCard") {
                SettingsValueRow("Log", value: "Not supported yet", identifier: "serverLogUnsupported")
            }
            SettingsFootnote(ServerHostCopy.unsupported, identifier: "serverLogFootnote")
        case .failed:
            FailureCard(
                message: "Couldn't read the log.", identifier: "serverLogFailure",
                retry: { Task { await host.loadLogs() } })
        case .loaded(let page):
            SettingsCard(identifier: "serverLogCard") {
                if !page.available {
                    SettingsValueRow("Log", value: "Nothing logged yet", identifier: "serverLogEmpty")
                } else {
                    logText
                    if host.hasOlderLines {
                        SettingsActionRow(
                            host.isLoadingOlder ? "Loading…" : "Show older lines",
                            identifier: "serverLogOlder", action: { Task { await host.loadOlder() } }
                        )
                        .disabled(host.isLoadingOlder)
                    }
                }
                SettingsActionRow(
                    "Refresh", identifier: "serverLogRefresh",
                    action: { Task { await host.loadLogs() } })
                if page.available, !host.logLines.isEmpty {
                    SettingsActionRow(
                        copied ? "Copied" : "Copy log", identifier: "serverLogCopy",
                        action: copy)
                }
            }
            SettingsFootnote(
                "Secrets are hidden before the log leaves this computer.", identifier: "serverLogFootnote")
        }
    }

    private var logText: some View {
        ScrollView {
            Text(host.logText)
                .settingsText(.rowSubtitle).monospaced()
                .foregroundStyle(Color(theme.palette.textPrimary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsSurface.rowInset)
                .padding(.vertical, SettingsSurface.rowVerticalPadding)
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
