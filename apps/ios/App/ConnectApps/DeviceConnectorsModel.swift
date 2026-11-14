import Foundation
import Observation
import PalDevice
import PalDiagnostics
import PalProtocol

struct DeviceSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [DeviceConnectorRow]
}

@MainActor
@Observable
final class DeviceConnectorsModel {
    private(set) var thisDevice: DeviceSection
    private(set) var busy: Set<DeviceConnectorID> = []

    #if os(macOS)
    let t3: T3CodeHost
    #endif
    private let pool: DeviceHostPool
    private let profile: String?
    private let permissions: any DevicePermissions
    private let diagnostics = Diagnostics.osLog()
    private let localKind = DeviceKind.current

    init(pool: DeviceHostPool, profile: String?, permissions: any DevicePermissions = SystemPermissions()) {
        self.pool = pool
        self.profile = profile
        self.permissions = permissions
        #if os(macOS)
        t3 = pool.t3Code
        #endif
        thisDevice = Self.localSection(kind: DeviceKind.current, reports: [:])
    }

    func start() async {
        await refresh()
    }

    func refresh() async {
        #if os(macOS)
        await t3.controller.refresh()
        #endif
        thisDevice = Self.localSection(kind: localKind, reports: await localReports())
    }

    func allow(_ id: DeviceConnectorID) async {
        busy.insert(id)
        defer { busy.remove(id) }
        let result = await permissions.request(id)
        diagnostics.info("device", "allow \(id.rawValue) os=\(result.rawValue)")
        if let ledger = await pool.stack(for: profile)?.ledger { await ledger.reportOSPermission(result, for: id) }
        await refresh()
    }

    func openSettings(for id: DeviceConnectorID) {
        let url: URL? = switch id {
        case .input: SystemSettings.accessibilitySettingsURL
        case .screen: SystemSettings.screenRecordingURL
        case .messages: SystemSettings.fullDiskAccessURL
        default: SystemSettings.appSettingsURL
        }
        if let url { SystemSettings.open(url) }
    }

    private func localReports() async -> [DeviceConnectorID: DeviceConnectorReport] {
        var reports: [DeviceConnectorID: DeviceConnectorReport] = [:]
        for entry in DeviceConnectorCatalog.entries(for: localKind) {
            reports[entry.id] = DeviceConnectorReport(id: entry.id, osPermission: await permissions.status(of: entry.id))
        }
        return reports
    }

    private static func localSection(kind: DeviceKind, reports: [DeviceConnectorID: DeviceConnectorReport]) -> DeviceSection {
        DeviceSection(id: "this-device", title: "This \(kind.sectionName)", rows: DeviceConnectorCatalog.rows(for: kind, reports: reports))
    }
}
