import Observation
import PalDesign
import PalProtocol
import SwiftUI

enum DiagnosticsCopy {
    static let title = String(localized: "Diagnostics")
    static let rowSubtitle = String(localized: "Recent problems on this device")
    static let emptyTitle = String(localized: "No problems")
    static let emptyBody = String(localized: "Problems Pal runs into on this device appear here.")
    static let copyAll = String(localized: "Copy All")
    static let clear = String(localized: "Clear")
    static let clearConfirm = String(localized: "Clear the problems listed on this device?")
    static let reported = String(localized: "Reported to gateway")

    static var appBuild: String {
        let info = Bundle.main.infoDictionary
        return [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]].compactMap { $0 as? String }.joined(separator: " ")
    }

    static func reason(_ code: String) -> String {
        switch code {
        case "offline": String(localized: "Pal couldn't reach your server.")
        case "timeout": String(localized: "Your server took too long to answer.")
        case "decode": String(localized: "Pal couldn't read your server's answer.")
        case "owner_only", "forbidden": String(localized: "Only the owner can do this.")
        case "invalid_params": String(localized: "Your server didn't accept the request.")
        case "not_implemented": String(localized: "Your server doesn't support this yet.")
        case "not_found": String(localized: "Your server couldn't find what Pal asked for.")
        default: String(localized: "Something went wrong on your server.")
        }
    }
}

@MainActor
@Observable
final class DiagnosticsModel {
    private(set) var records: [FaultRecord]?
    private let store: FaultStore

    init(store: FaultStore = .shared) {
        self.store = store
    }

    func watch() async {
        let changes = await store.changes()
        records = await store.records()
        for await _ in changes { records = await store.records() }
    }

    func clear() async {
        await store.clear()
        records = await store.records()
    }

    var allText: String { FaultRecord.lines(records ?? [], appVersion: DiagnosticsCopy.appBuild) }
}

struct FaultSummary: View {
    let record: FaultRecord

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(record.method)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(record.at, format: .relative(presentation: .named))
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
            }
            Text(DiagnosticsCopy.reason(record.reason))
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("diagnosticsReason")
            Text(summaryLine)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .accessibilityIdentifier("diagnosticsTrace")
            if record.reported {
                Label(DiagnosticsCopy.reported, palIcon: "checkmark.circle", ink: .secondary)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("diagnosticsReported")
            }
        }
    }

    private var summaryLine: String {
        [record.reason, record.code.map { "\($0)" }, "trace \(record.trace)", record.gatewayVersion.map { "gateway \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct FaultDetails: View {
    let record: FaultRecord

    @State private var expanded = false
    @State private var sharing = false
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        DisclosureGroup(String(localized: "Details"), isExpanded: $expanded) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    detail("reason \(record.reason)" + (record.code.map { ", code \($0)" } ?? ""))
                    detail("trace \(record.trace)")
                    detail("source \(record.source)")
                    detail("gateway \(record.gatewayVersion ?? "-")")
                    detail("app \(DiagnosticsCopy.appBuild)")
                    detail(record.at.formatted(date: .abbreviated, time: .standard))
                }
                .textSelection(.enabled)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    Button(String(localized: "Copy")) { Pasteboard.string = copyText }
                        .buttonStyle(.pill())
                        .accessibilityIdentifier("diagnosticsCopy")
                    #if os(iOS)
                    Button(String(localized: "Share")) { sharing = true }
                        .buttonStyle(.pill())
                        .accessibilityIdentifier("diagnosticsShare")
                    #endif
                }
            }
            .padding(.top, 8)
        }
        .hermesText(.rowSubtitle)
        .foregroundStyle(Color(theme.palette.textSecondary))
        .accessibilityIdentifier("diagnosticsDetails")
        .shareSheet(isPresented: $sharing) { [copyText] }
    }

    private var copyText: String { record.copyText(appVersion: DiagnosticsCopy.appBuild) }

    private func detail(_ text: String) -> some View {
        Text(text).hermesText(.rowSubtitle).foregroundStyle(Color(theme.palette.textSecondary))
    }
}

struct DiagnosticsEmpty: View {
    var body: some View {
        ContentUnavailableView {
            Label(DiagnosticsCopy.emptyTitle, palIcon: "checkmark.seal")
        } description: {
            Text(DiagnosticsCopy.emptyBody)
        }
            .accessibilityIdentifier("diagnosticsEmpty")
    }
}

struct DiagnosticsScreen: View {
    let back: () -> Void

    @State private var model = DiagnosticsModel()
    @State private var confirmingClear = false

    var body: some View {
        SettingsPage(
            title: DiagnosticsCopy.title, identifier: "diagnosticsScreen", back: back,
            trailing: {
                Menu {
                    Button { Pasteboard.string = model.allText } label: { Label(DiagnosticsCopy.copyAll, palIcon: "doc.on.doc") }
                        .accessibilityIdentifier("diagnosticsCopyAll")
                    Button(role: .destructive) { confirmingClear = true } label: { Label(DiagnosticsCopy.clear, palIcon: "trash", ink: .destructive) }
                        .accessibilityIdentifier("diagnosticsClear")
                } label: {
                    PalIcon("ellipsis")
                }
                .disabled(model.records?.isEmpty ?? true)
                .accessibilityLabel(Text(String(localized: "Diagnostics actions")))
                .accessibilityIdentifier("diagnosticsActions")
            },
            content: {
                if let records = model.records {
                    if records.isEmpty {
                        DiagnosticsEmpty().padding(.top, 40)
                    } else {
                        ForEach(records) { record in
                            GroupedCard(accessibilityIdentifier: "diagnosticsRow") {
                                VStack(alignment: .leading, spacing: 8) {
                                    FaultSummary(record: record)
                                    FaultDetails(record: record)
                                }
                                .padding(.horizontal, PalMetrics.rowInset)
                                .padding(.vertical, PalMetrics.rowVerticalPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        )
        .task { await model.watch() }
        .macConfirm(isPresented: $confirmingClear) {
            MacDialogContent(
                DiagnosticsCopy.clearConfirm,
                actions: [
                    MacDialogAction(DiagnosticsCopy.clear, role: .destructive, identifier: "diagnosticsClearConfirm") { Task { await model.clear() } },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }
}

#if os(macOS)
struct MacDiagnosticsSection: View {
    @State private var model = DiagnosticsModel()
    @State private var confirmingClear = false

    var body: some View {
        MacSectionPage(section: .diagnostics) {
            HStack(spacing: 8) {
                Button(DiagnosticsCopy.copyAll) { Pasteboard.string = model.allText }
                    .buttonStyle(.palPill)
                    .accessibilityIdentifier("diagnosticsCopyAll")
                Button(DiagnosticsCopy.clear, role: .destructive) { confirmingClear = true }
                    .buttonStyle(.palPill)
                    .accessibilityIdentifier("diagnosticsClear")
            }
            .disabled(model.records?.isEmpty ?? true)
        } content: {
            if let records = model.records {
                if records.isEmpty {
                    DiagnosticsEmpty().padding(.top, 40)
                } else {
                    MacCard(identifier: "diagnosticsCard") {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                FaultSummary(record: record)
                                FaultDetails(record: record)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("diagnosticsRow")
                        }
                    }
                }
            }
        }
        .task { await model.watch() }
        .macConfirm(isPresented: $confirmingClear) {
            MacDialogContent(
                DiagnosticsCopy.clearConfirm,
                actions: [
                    MacDialogAction(DiagnosticsCopy.clear, role: .destructive, identifier: "diagnosticsClearConfirm") { Task { await model.clear() } },
                    MacDialogAction(String(localized: "Cancel"), role: .cancel),
                ]
            )
        }
    }
}
#endif
