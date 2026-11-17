#if os(macOS)
import PalBotProfile
import PalConnect
import PalDesign
import PalDevice
import PalProtocol
import PalT3Code
import SwiftUI

extension MacConnectApps {
    var header: some View {
        HStack {
            if onCatalog {
                Text("Connect Apps")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Button { model.page = .catalog } label: { // nav-chrome: ok
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Your plugins").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(PalTokens.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectAppsBack")
            }
            Spacer()
            if onCatalog { connectedCount }
        }
        .padding(.leading, 29)
        .padding(.trailing, 38)
        .padding(.top, 47)
        .frame(height: 71, alignment: .top)
    }

    var connectedCount: some View {
        Button { model.page = .yourPlugins } label: {
            HStack(spacing: 6) {
                stackedIcons
                HStack(spacing: 4) {
                    Text("\(model.connectedCount) connected")
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(PalTokens.textSecondary)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(model.connectedCount) connected"))
        .accessibilityIdentifier("connectedCountButton")
    }

    var stackedIcons: some View {
        HStack(spacing: -3) {
            ForEach(Array(model.connectedApps.prefix(4).enumerated()), id: \.element.id) { index, _ in
                MacAppTile(size: 16, radius: 4, glyphSize: 8)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(PalTokens.elevated, lineWidth: 1))
                    .zIndex(Double(-index))
            }
        }
        .accessibilityHidden(true)
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(PalTokens.textSecondary)
            TextField("Search across apps and skills", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityIdentifier("connectAppsSearch")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .palGlass(RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: false)
    }

    var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.chips, id: \.self) { chip in chipButton(chip) }
            }
            .padding(.horizontal, 29)
        }
        .scrollIndicators(.never)
        .frame(height: 25)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectAppsChips")
    }

    func chipTitle(_ id: String) -> String {
        switch id {
        case ConnectChip.all: String(localized: "All")
        default: id
        }
    }

    func chipButton(_ id: String) -> some View {
        let selected = model.selection == id && model.trimmedQuery.isEmpty
        return Button { model.selection = id; model.query = "" } label: {
            Text(chipTitle(id))
                .font(.system(size: 12))
                .foregroundStyle(selected ? PalTokens.inverseText : PalTokens.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(selected ? PalTokens.inverseFill : PalTokens.chipFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("connectAppsChips-\(id)")
    }

    @ViewBuilder
    var catalogContent: some View {
        switch model.phase {
        case .loading where model.catalog.apps.isEmpty:
            DelayedProgressView().frame(maxWidth: .infinity).padding(.top, 60).accessibilityIdentifier("connectAppsLoading")
        case .unavailable:
            VStack(spacing: 14) {
                Text("Couldn't load apps").foregroundStyle(PalTokens.textSecondary)
                Button("Try again") { Task { await model.reload() } }
                    .buttonStyle(.palPill)
                    .accessibilityIdentifier("connectAppsRetry")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .accessibilityIdentifier("connectAppsUnavailable")
        default:
            if !model.trimmedQuery.isEmpty { searchResults } else { selectedSection }
        }
    }

    @ViewBuilder
    var selectedSection: some View {
        switch model.selection {
        case ConnectChip.all:
            deviceSection(model.devices.thisDevice)
            ForEach(model.catalog.categories, id: \.self) { category in
                section(title: category, identifier: "connectAppsSection-\(category)", viewAll: { model.selection = category }, content: {
                    appGrid(Array(model.catalog.apps(in: category).prefix(Self.rowsPerSectionInAll)))
                })
            }
            capabilitiesSection
        case let category:
            section(title: category, identifier: "connectAppsSectionTitle", viewAll: nil) {
                appGrid(model.catalog.apps(in: category))
            }
        }
    }

    func section<Body: View>(title: String, identifier: String, viewAll: (() -> Void)?, @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier)
                Spacer()
                if let viewAll {
                    Button("View all", action: viewAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textSecondary)
                        .accessibilityIdentifier("\(identifier)-viewAll")
                }
            }
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .kanbanGlass(RoundedRectangle(cornerRadius: PalMetrics.tileRadius, style: .continuous))
        }
    }

    @ViewBuilder
    var capabilitiesSection: some View {
        switch model.capabilitiesPhase {
        case .hidden:
            EmptyView()
        case .loading:
            section(title: String(localized: "Capabilities"), identifier: "capabilitiesTitle", viewAll: nil) {
                DelayedProgressView().controlSize(.small).accessibilityIdentifier("capabilitiesLoading")
            }
        case .failed:
            section(title: String(localized: "Capabilities"), identifier: "capabilitiesTitle", viewAll: nil) {
                Text("Couldn't load capabilities")
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textSecondary)
                    .accessibilityIdentifier("capabilitiesError")
            }
        case .ready(let rows):
            if !rows.isEmpty {
                section(title: String(localized: "Capabilities"), identifier: "capabilitiesTitle", viewAll: nil) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in MacCapabilityRow(row: row, onSetKey: model.canSetKeys ? { model.beginKeyEntry(row, keyName: $0) } : nil) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capabilitiesList")
                }
            }
        }
    }

    func deviceSection(_ device: DeviceSection) -> some View {
        section(title: device.title, identifier: "connectAppsSection-device-\(device.id)", viewAll: nil) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(device.rows) { deviceRow($0) }
                MacT3CodeRow(host: model.devices.t3) { confirmsT3Disconnect = true }
            }
        }
    }

    func deviceRow(_ row: DeviceConnectorRow) -> some View {
        let look = DeviceRowPresentation(row: row)
        let identifier = "deviceConnector-\(row.id.rawValue)"
        return HStack(spacing: 8) {
            DeviceTile(connector: row.id).scaleEffect(0.95).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.title)
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                Text(look.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(PalTokens.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if model.devices.busy.contains(row.id) {
                ProgressView().controlSize(.small)
            } else if let action = deviceAction(look, row.id) {
                action.view(identifier: "\(identifier)-action")
            }
        }
        .frame(height: 60.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    func deviceAction(_ look: DeviceRowPresentation, _ id: DeviceConnectorID) -> MacRowAction? {
        guard let title = look.buttonTitle else { return nil }
        let localized = String(localized: String.LocalizationValue(title))
        switch look.action {
        case .allow: return MacRowAction(title: localized, prominent: true) { Task { await model.devices.allow(id) } }
        case .openSettings: return MacRowAction(title: localized, prominent: true) { model.devices.openSettings(for: id) }
        case nil: return MacRowAction(title: localized, checked: true) {}
        }
    }

    func appGrid(_ apps: [ConnectApp]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(apps) { appRow($0) }
        }
    }
}
#endif
