import PalDevice
import PalProtocol
import Testing

struct DeviceConnectorCatalogTests {
    @Test func iphoneListsExactlyTheSixIphoneConnectors() {
        let ids = DeviceConnectorCatalog.entries(for: .ios).map(\.id)
        #expect(ids == [.calendar, .home, .reminders, .contacts, .location, .alarms])
    }

    @Test func macListsExactlyTheMacConnectors() {
        let ids = DeviceConnectorCatalog.entries(for: .mac).map(\.id)
        #expect(ids == [.calendar, .home, .reminders, .contacts, .location, .alarms, .notifications, .input, .clipboard, .screen, .apps, .messages])
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

    @Test func offlineDeviceWinsOverAnyReportedPermission() {
        #expect(DeviceConnectorRowState(osPermission: .granted, online: false) == .offline)
        #expect(DeviceConnectorRowState(osPermission: nil, online: false) == .offline)
    }

    @Test func missingFieldsDecodeAsUnknownNotAsAllowed() {
        let value: JSONValue = .object(["connectors": .array([
            .object(["id": .string("calendar")]),
            .object(["id": .string("home"), "os_permission": .string("granted")]),
            .object(["id": .string("reminders"), "os_permission": .string("something_new")]),
            .object(["id": .string("telepathy"), "os_permission": .string("granted")]),
            .object(["os_permission": .string("granted")]),
        ])])
        let reports = DeviceConnectorReport.decode(value)
        #expect(reports[.calendar]?.osPermission == nil)
        #expect(reports[.home]?.osPermission == .granted)
        #expect(reports[.reminders]?.osPermission == nil)
        #expect(reports.count == 3)
        let rows = DeviceConnectorCatalog.rows(for: .ios, reports: reports)
        #expect(rows.first { $0.id == .calendar }?.state == .unknown)
        #expect(rows.first { $0.id == .contacts }?.state == .unknown)
        #expect(rows.first { $0.id == .home }?.state == .allowed)
    }

    @Test func undecodableResultYieldsNoReports() {
        #expect(DeviceConnectorReport.decode(.null).isEmpty)
        #expect(DeviceConnectorReport.decode(.object(["connectors": .string("nope")])).isEmpty)
    }

    @Test func thisDeviceOffersOnlyPermissionActionsNeverASwitch() {
        for state in [DeviceConnectorRowState.allowed, .allow, .needsSystemPermission, .unavailable, .offline, .unknown] {
            let row = DeviceConnectorRow(entry: DeviceConnectorCatalog.entries(for: .mac)[0], state: state)
            let look = DeviceRowPresentation(row: row, isThisDevice: true)
            #expect(look.action == nil || look.action == .allow || look.action == .openSettings)
        }
    }

    @Test func allowedAndAllowAndSettingsButtonsOnThisDevice() {
        let entry = DeviceConnectorCatalog.entries(for: .ios)[0]
        let allowed = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .allowed), isThisDevice: true)
        let allow = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .allow), isThisDevice: true)
        let denied = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .needsSystemPermission), isThisDevice: true)
        #expect(allowed.buttonTitle == "Allowed" && allowed.action == nil)
        #expect(allow.buttonTitle == "Allow" && allow.action == .allow)
        #expect(denied.buttonTitle == "Open Settings" && denied.action == .openSettings)
        #expect(denied.summary == "Needs a system permission")
    }

    @Test func otherDevicesAreReadOnlyWithTheOpenPalNote() {
        let entry = DeviceConnectorCatalog.entries(for: .mac)[0]
        for state in [DeviceConnectorRowState.allowed, .allow, .needsSystemPermission, .unavailable, .offline, .unknown] {
            let look = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: state), isThisDevice: false)
            #expect(look.buttonTitle == nil)
            #expect(look.action == nil)
        }
        let needs = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .allow), isThisDevice: false)
        #expect(needs.summary.contains(DeviceRowPresentation.remoteNote))
    }

    @Test func unavailableAndOfflineAreLabelled() {
        let entry = DeviceConnectorCatalog.entries(for: .mac)[0]
        let unavailable = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .unavailable), isThisDevice: true)
        let offline = DeviceRowPresentation(row: DeviceConnectorRow(entry: entry, state: .offline), isThisDevice: false)
        #expect(unavailable.summary == "Not available on this device")
        #expect(offline.summary == "Offline")
    }
}
