import Foundation
import Observation
import PalDevice
import PalDiagnostics
import PalProtocol
import PalSettings

struct DeviceSection: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: DeviceKind
    let isThisDevice: Bool
    let online: Bool
    let rows: [DeviceConnectorRow]
}

@MainActor
@Observable
final class DeviceConnectorsModel {
    private(set) var sections: [DeviceSection] = []
    private(set) var busy: Set<DeviceConnectorID> = []
    private(set) var failedToLoadOthers = false

    private let connection: ConnectionModel
    private let pool: DeviceHostPool
    private let profile: String?
    private let permissions: any DevicePermissions
    private let diagnostics = Diagnostics.osLog()
    private let localKind = DeviceKind.current

    init(connection: ConnectionModel, pool: DeviceHostPool, profile: String?, permissions: any DevicePermissions = SystemPermissions()) {
        self.connection = connection
        self.pool = pool
        self.profile = profile
        self.permissions = permissions
        sections = [localSection(reports: [:])]
    }

    func sections(of kind: DeviceKind) -> [DeviceSection] {
        sections.filter { $0.kind == kind }
    }

    var thisDevice: DeviceSection? { sections.first { $0.isThisDevice } }

    func start() async {
        await refresh()
    }

    func refresh() async {
        let local = await localReports()
        sections = [localSection(reports: local)] + (await otherSections())
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

    private func localSection(reports: [DeviceConnectorID: DeviceConnectorReport]) -> DeviceSection {
        DeviceSection(
            id: "this-device", title: "This \(localKind.sectionName)", kind: localKind, isThisDevice: true, online: true,
            rows: DeviceConnectorCatalog.rows(for: localKind, reports: reports)
        )
    }

    private func otherSections() async -> [DeviceSection] {
        guard let devices = await loadDevices() else {
            failedToLoadOthers = true
            return []
        }
        failedToLoadOthers = false
        let others = DeviceEntry.ordered(devices, localDeviceID: connection.localDeviceID).filter { !$0.isThisDevice }
        var result: [DeviceSection] = []
        for entry in others {
            guard let section = await otherSection(entry, kind: devices.first { $0.deviceId == entry.id }?.kind) else { continue }
            result.append(section)
        }
        return result
    }

    private func otherSection(_ entry: DeviceEntry, kind wire: String?) async -> DeviceSection? {
        guard let kind = wire.flatMap(DeviceKind.init(rawValue:)) else { return nil }
        let reports = entry.isOnline ? await remoteReports(entry.id) : [:]
        return DeviceSection(
            id: entry.id, title: entry.name, kind: kind, isThisDevice: false, online: entry.isOnline,
            rows: DeviceConnectorCatalog.rows(for: kind, reports: reports, online: entry.isOnline)
        )
    }

    private func loadDevices() async -> [SettingsWire.Device]? {
        guard let value = try? await connection.rpc("devices.list", .object([:])) else { return nil }
        return (try? value.decoded(as: SettingsWire.DevicesList.self, using: SettingsWire.decoder))?.devices
    }

    private func remoteReports(_ deviceID: String) async -> [DeviceConnectorID: DeviceConnectorReport] {
        guard let value = try? await connection.rpc("device_connectors.list", ["device_id": .string(deviceID)]) else { return [:] }
        return DeviceConnectorReport.decode(value)
    }
}
