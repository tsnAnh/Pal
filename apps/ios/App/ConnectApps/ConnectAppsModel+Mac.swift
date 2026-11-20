import Foundation
import PalConnect
import PalDevice
import PalDiagnostics
import PalProtocol

struct ConnectRowCache {
    struct Key: Equatable {
        let revision: Int
        let busy: Set<String>
        let failures: [String: String]
        let t3Reach: T3Reach?
        let bot: ConnectBotInstall
    }

    let key: Key
    let entries: [ConnectListEntry]
}

struct ConnectMacKey: Equatable {
    let rows: ConnectRowCache.Key
    let query: String
    let chip: ConnectChip
    let device: DeviceSection
    let keeping: Set<String>
}

struct ConnectMacSectionEntries: Identifiable {
    let section: ConnectMacSection
    let entries: [ConnectListEntry]

    var id: String { section.id }
}

struct ConnectInstalledItem: Identifiable {
    enum Source {
        case app(ConnectApp)
        case device(DeviceConnectorID)
    }

    let id: String
    let name: String
    let source: Source

    var countLine: String { ConnectCountLine.text(connectors: 1) }
}

struct ConnectMacState {
    let chips: ConnectChipBar
    let sections: [ConnectMacSectionEntries]
    let deviceRows: [DeviceConnectorRow]
    let installed: [ConnectInstalledItem]
    let skills: [InstalledSkill]
    let privateSkills: [InstalledSkill]
}

struct ConnectMacCache {
    let key: ConnectMacKey
    let state: ConnectMacState
}

extension ConnectAppsModel {
    var macState: ConnectMacState {
        let entries = cachedEntries()
        let device = devices.thisDevice
        let key = ConnectMacKey(rows: rowCacheKey, query: trimmedQuery, chip: chip, device: device, keeping: justConnected)
        if let held = macCache, held.key == key { return held.state }
        let perf = PalPerf.begin("connect.sections.main"); defer { perf.end() }
        sectionBuilds += 1
        let needle = key.query
        let matched = needle.isEmpty ? entries : entries.filter { ConnectCatalog.matches($0.app, needle: needle) }
        let byID = Dictionary(matched.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })
        let deviceRows = device.rows.filter { $0.state != .allowed }
        let sections = ConnectMacLayout.sections(
            rows: matched.map(\.row), categories: catalog.categories, chip: chip, isSearching: !needle.isEmpty,
            device: (title: device.title, count: deviceRows.count), keeping: justConnected
        )
        .map { section in ConnectMacSectionEntries(section: section, entries: section.rows.compactMap { byID[$0.id] }) }
        let installedApps = entries.filter { $0.row.state == .connected }.map {
            ConnectInstalledItem(id: $0.app.id, name: $0.row.name, source: .app($0.app))
        }
        let installedDevices = device.rows.filter { $0.state == .allowed }.map {
            ConnectInstalledItem(id: "device:\($0.id.rawValue)", name: $0.entry.title, source: .device($0.id))
        }
        let state = ConnectMacState(
            chips: ConnectChipBar(rows: entries.map(\.row), categories: catalog.categories), sections: sections, deviceRows: deviceRows,
            installed: installedApps + installedDevices, skills: catalog.matchingSkills(needle),
            privateSkills: catalog.privateSkills
        )
        macCache = ConnectMacCache(key: key, state: state)
        return state
    }

    func isExpanded(_ section: ConnectMacSection) -> Bool { expandedSections.contains(section.id) }

    func toggleExpanded(_ section: ConnectMacSection) {
        if !expandedSections.insert(section.id).inserted { expandedSections.remove(section.id) }
    }

    func selectChip(_ next: ConnectChip) {
        query = ""
        chip = next
    }

    func showInstalled() {
        navigation.showInstalled()
    }

    func leaveInstalled() {
        navigation.back()
        showsAllInstalled = false
    }
}
