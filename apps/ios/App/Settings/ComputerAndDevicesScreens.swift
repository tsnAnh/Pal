import PalDesign
import PalProtocol
import PalSettings
import Observation
import SwiftUI

@MainActor
@Observable
final class BotComputerSettingsModel {
    private(set) var state: Loadable<ComputerSummary> = .loading
    private(set) var isResetting = false
    private(set) var notice: String?
    var failure: String?

    private let surfaces: SurfaceCache
    private static let surfaceKey = SurfaceKey.screen("bot-computer-disk")

    init(surfaces: SurfaceCache) {
        self.surfaces = surfaces
        if let held = surfaces.remembered(ComputerSummary.self, Self.surfaceKey) { state = .loaded(held) }
    }

    func load(api: SettingsAPI) async {
        do {
            let summary = ComputerSummary(try await api.displayStatus())
            state = .loaded(summary)
            surfaces.remember(summary, Self.surfaceKey)
        } catch is CancellationError {
            return
        } catch {
            if state.value == nil { state = .failed(SettingsFailure(error).message) }
        }
    }

    func reset(api: SettingsAPI) async {
        isResetting = true
        notice = nil
        defer { isResetting = false }
        do {
            let summary = ComputerSummary(try await api.resetDisplay())
            state = .loaded(summary)
            surfaces.remember(summary, Self.surfaceKey)
            notice = "Computer reset. It will rebuild the next time a Bot needs it."
        } catch {
            failure = SettingsFailure(error).message
        }
    }
}

struct BotComputerScreen: View {
    let hub: SettingsHub
    let back: () -> Void

    @State private var model: BotComputerSettingsModel
    @State private var confirming = false

    init(hub: SettingsHub, back: @escaping () -> Void) {
        self.hub = hub
        self.back = back
        _model = State(initialValue: BotComputerSettingsModel(surfaces: hub.connection.surfaces))
    }

    var body: some View {
        SettingsPage(title: "Bot Computer", identifier: "botComputerScreen", back: back) {
            VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                GroupedCard(accessibilityIdentifier: "botComputerResetCard") {
                    SettingsRow(
                        title: "Reset Computer",
                        subtitle: "Rebuild from your last saved snapshot. Very recent changes may be lost.",
                        role: .destructive, accessibilityIdentifier: "botComputerResetRow",
                        action: { confirming = true }
                    )
                    .disabled(model.isResetting)
                }
                CardFootnote(model.notice ?? "The one computer your Bots share.", accessibilityIdentifier: "botComputerFootnote")
            }
            GroupedCard(accessibilityIdentifier: "botComputerDiskCard") {
                switch model.state {
                case .loading:
                    SettingsRow.value("Disk space", value: " ", accessibilityIdentifier: "botComputerDisk")
                case .loaded(let summary):
                    SettingsRow.value("Disk space", value: summary.disk.text, accessibilityIdentifier: "botComputerDisk")
                case .failed(let message):
                    SettingsRow.value("Disk space", value: "Unavailable", subtitle: message, accessibilityIdentifier: "botComputerDisk")
                }
            }
        }
        .task { await model.load(api: hub.api) }
        .confirmationDialog("Reset Computer?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset Computer", role: .destructive) { Task { await model.reset(api: hub.api) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rebuild from your last saved snapshot. Very recent changes may be lost.")
        }
        .alert("Bot Computer", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}

@MainActor
@Observable
final class DevicesModel {
    private(set) var state: Loadable<[DeviceEntry]> = .loading
    var failure: String?

    private let surfaces: SurfaceCache
    private static let surfaceKey = SurfaceKey.screen("devices")

    init(surfaces: SurfaceCache) {
        self.surfaces = surfaces
    }

    func load(api: SettingsAPI, localDeviceID: String?) async {
        if state.value == nil, let cached = await surfaces.value([DeviceEntry].self, Self.surfaceKey), state.value == nil {
            state = .loaded(cached)
        }
        do {
            let devices = DeviceEntry.ordered(try await api.devices(), localDeviceID: localDeviceID)
            state = .loaded(devices)
            surfaces.persist(devices, Self.surfaceKey)
        } catch is CancellationError {
            return
        } catch {
            if state.value == nil { state = .failed(SettingsFailure(error).message) }
        }
    }

    func forget(_ device: DeviceEntry, api: SettingsAPI, localDeviceID: String?) async -> Bool {
        do {
            try await api.forgetDevice(id: device.id)
            await load(api: api, localDeviceID: localDeviceID)
            return true
        } catch {
            failure = SettingsFailure(error).message
            return false
        }
    }
}

struct DevicesScreen: View {
    let hub: SettingsHub
    let connection: ConnectionModel
    let back: () -> Void

    @State private var model: DevicesModel
    @State private var selected: DeviceEntry?

    init(hub: SettingsHub, connection: ConnectionModel, back: @escaping () -> Void) {
        self.hub = hub
        self.connection = connection
        self.back = back
        _model = State(initialValue: DevicesModel(surfaces: connection.surfaces))
    }

    var body: some View {
        Group {
            if let selected {
                DeviceDetailScreen(device: selected, model: model, hub: hub, connection: connection) { self.selected = nil }
            } else {
                list
            }
        }
        .task { await model.load(api: hub.api, localDeviceID: connection.localDeviceID) }
    }

    private var list: some View {
        SettingsPage(title: "Manage your devices", identifier: "devicesScreen", back: back) {
            switch model.state {
            case .loading:
                GroupedCard(accessibilityIdentifier: "devicesLoading") {
                    LoadingRow(title: "Devices", identifier: "devicesLoadingRow")
                }
            case .failed(let message):
                FailureCard(message: message, identifier: "devicesFailure") {
                    Task { await model.load(api: hub.api, localDeviceID: connection.localDeviceID) }
                }
            case .loaded(let devices):
                GroupedCard(accessibilityIdentifier: "devicesCard") {
                    ForEach(devices) { device in
                        SignedInDeviceRow(device: device) { selected = device }
                    }
                }
            }
        }
        .refreshable { await model.load(api: hub.api, localDeviceID: connection.localDeviceID) }
    }
}

private struct SignedInDeviceRow: View {
    let device: DeviceEntry
    let open: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        LeadingSettingsRow(
            title: device.name, subtitle: device.subtitle(now: Date()), trailing: .chevron, leadingSpacing: 8,
            accessibilityIdentifier: "device-\(device.id)", action: open
        ) {
            HStack(spacing: 8) {
                StatusDot(isOn: device.isOnline)
                Image(systemName: device.symbolName)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 65)
    }
}

private struct DeviceDetailScreen: View {
    let device: DeviceEntry
    let model: DevicesModel
    let hub: SettingsHub
    let connection: ConnectionModel
    let back: () -> Void

    @State private var confirming = false

    var body: some View {
        SettingsPage(title: device.name, identifier: "deviceDetailScreen", back: back) {
            GroupedCard(accessibilityIdentifier: "deviceDetailCard") {
                SettingsRow.value("Type", value: device.kindLabel, accessibilityIdentifier: "deviceDetailType")
                SettingsRow.value(
                    "Status", value: device.statusText(now: Date()), accessibilityIdentifier: "deviceDetailStatus"
                )
            }
            if !device.isThisDevice {
                GroupedCard(accessibilityIdentifier: "deviceRemoveCard") {
                    SettingsRow.destructive("Remove Device", accessibilityIdentifier: "deviceRemoveRow", action: { confirming = true })
                }
            }
        }
        .confirmationDialog(
            "Remove \(device.name)?", isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { if await model.forget(device, api: hub.api, localDeviceID: connection.localDeviceID) { back() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be signed out and will stop receiving notifications.")
        }
        .alert("Devices", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }
}
