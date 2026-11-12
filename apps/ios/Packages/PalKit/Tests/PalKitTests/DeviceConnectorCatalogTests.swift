import PalDevice
import Testing

struct DeviceConnectorCatalogTests {
    @Test func iphoneListsExactlyTheSixIphoneConnectors() {
        let ids = DeviceConnectorCatalog.entries(for: .ios).map(\.id)
        #expect(ids == [.calendar, .home, .reminders, .contacts, .location, .alarms])
    }

    @Test func macListsExactlyTheMacConnectors() {
        let ids = DeviceConnectorCatalog.entries(for: .mac).map(\.id)
        #expect(ids == [.calendar, .home, .reminders, .contacts, .location, .alarms, .notifications, .input, .clipboard, .screen, .apps])
    }

    @Test func shellAndFilesNeverGetARow() {
        for kind in DeviceKind.allCases {
            let ids = DeviceConnectorCatalog.entries(for: kind).map(\.id)
            #expect(!ids.contains(.shell))
            #expect(!ids.contains(.files))
        }
    }

    @Test func rowsAreUniquePerKind() {
        for kind in DeviceKind.allCases {
            let ids = DeviceConnectorCatalog.entries(for: kind).map(\.id)
            #expect(Set(ids).count == ids.count)
        }
    }

    @Test func permissionMapsToRowState() {
        #expect(DeviceConnectorRowState(osPermission: .granted) == .allowed)
        #expect(DeviceConnectorRowState(osPermission: .notDetermined) == .allow)
        #expect(DeviceConnectorRowState(osPermission: .denied) == .needsSystemPermission)
        #expect(DeviceConnectorRowState(osPermission: .unsupported) == .unavailable)
        #expect(DeviceConnectorRowState(osPermission: nil) == .unknown)
    }

    @Test func rowsWithoutAReportAreUnknownNotAllowed() {
        let reports = [DeviceConnectorID.home: DeviceConnectorReport(id: .home, osPermission: .granted)]
        let rows = DeviceConnectorCatalog.rows(for: .ios, reports: reports)
        #expect(rows.first { $0.id == .calendar }?.state == .unknown)
        #expect(rows.first { $0.id == .home }?.state == .allowed)
    }

    @Test func allowedAndAllowAndSettingsButtonsOnThisDevice() {
        let entry = DeviceConnectorCatalog.entries(for: .ios)[0]
        let allowed = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .allowed))
        let allow = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .allow))
        let denied = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .needsSystemPermission))
        #expect(allowed.buttonTitle == "Allowed" && allowed.action == nil)
        #expect(allow.buttonTitle == "Allow" && allow.action == .allow)
        #expect(denied.buttonTitle == "Open Settings" && denied.action == .openSettings)
        #expect(denied.summary == "Needs a system permission")
    }

    @Test func unavailableIsLabelled() {
        let entry = DeviceConnectorCatalog.entries(for: .mac)[0]
        let unavailable = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .unavailable))
        #expect(unavailable.summary == "Not available on this device")
    }
}
