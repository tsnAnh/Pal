import Foundation

public enum ConnectChip: Hashable, Sendable {
    case all
    case thisDevice
    case featured
    case category(String)
}

public struct ConnectChipBar: Equatable, Sendable {
    public static let visibleCategoryLimit = 3

    public let leading: [String]
    public let more: [String]

    public init(rows: [ConnectListRow], categories: [String]) {
        var counts: [String: Int] = [:]
        for row in rows where row.state != .connected { counts[row.category, default: 0] += 1 }
        var order: [String: Int] = [:]
        for (index, name) in categories.enumerated() { order[name] = index }
        let ranked = counts.keys.sorted { lhs, rhs in
            let (left, right) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
            if left != right { return left > right }
            let (leftRank, rightRank) = (order[lhs] ?? Int.max, order[rhs] ?? Int.max)
            return leftRank != rightRank ? leftRank < rightRank : lhs < rhs
        }
        leading = Array(ranked.prefix(Self.visibleCategoryLimit))
        more = Array(ranked.dropFirst(Self.visibleCategoryLimit))
    }

    public func moreIsSelected(_ chip: ConnectChip) -> Bool {
        if case .category(let name) = chip { more.contains(name) } else { false }
    }
}

public struct ConnectMacSection: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case needsAttention
        case thisDevice
        case featured
        case category(String)
        case results

        public var chip: ConnectChip? {
            switch self {
            case .needsAttention, .results: nil
            case .thisDevice: .thisDevice
            case .featured: .featured
            case .category(let name): .category(name)
            }
        }
    }

    public let kind: Kind
    public let title: String
    public let rows: [ConnectListRow]
    public let total: Int

    public init(kind: Kind, title: String, rows: [ConnectListRow] = [], total: Int? = nil) {
        self.kind = kind
        self.title = title
        self.rows = rows
        self.total = total ?? rows.count
    }

    public var id: String {
        switch kind {
        case .needsAttention: "needs-attention"
        case .thisDevice: "this-device"
        case .featured: "featured"
        case .category(let name): "category-\(name)"
        case .results: "results"
        }
    }

    public var hasViewAll: Bool { total > ConnectMacLayout.collapsedRowLimit }

    public func visibleCount(expanded: Bool) -> Int { ConnectMacLayout.visibleCount(total: total, expanded: expanded) }
}

public enum ConnectMacLayout {
    public static let collapsedRowLimit = 6

    public static func visibleCount(total: Int, expanded: Bool) -> Int {
        expanded ? total : min(total, collapsedRowLimit)
    }

    public static func connectedCount(rows: [ConnectListRow], devicesAllowed: Int) -> Int {
        rows.filter { $0.state == .connected }.count + devicesAllowed
    }

    public static func sections(
        rows: [ConnectListRow], categories: [String], chip: ConnectChip, isSearching: Bool,
        device: (title: String, count: Int), keeping: Set<String> = [], includesFeatured: Bool = false
    ) -> [ConnectMacSection] {
        let gridded = rows.filter { $0.state != .connected || keeping.contains($0.id) }
        if isSearching {
            return gridded.isEmpty ? [] : [ConnectMacSection(kind: .results, title: String(localized: "Results"), rows: gridded)]
        }
        let deviceSection = device.count > 0 ? ConnectMacSection(kind: .thisDevice, title: device.title, total: device.count) : nil
        let featuredSection = includesFeatured ? featured(rows) : nil
        switch chip {
        case .thisDevice:
            return deviceSection.map { [$0] } ?? []
        case .featured:
            guard includesFeatured else { return grouped(gridded, categories: categories, device: deviceSection, featured: nil) }
            return featuredSection.map { [$0] } ?? []
        case .all:
            return grouped(gridded, categories: categories, device: deviceSection, featured: featuredSection)
        case .category(let name):
            return grouped(gridded.filter { $0.category == name }, categories: categories, device: nil, featured: nil)
        }
    }

    private static func isAttention(_ row: ConnectListRow) -> Bool {
        if case .needsAttention = row.state { true } else { false }
    }

    private static func featured(_ rows: [ConnectListRow]) -> ConnectMacSection? {
        let picked = rows.filter { $0.featured && !isAttention($0) }
        return picked.isEmpty ? nil : ConnectMacSection(kind: .featured, title: String(localized: "Featured"), rows: picked)
    }

    private static func grouped(
        _ rows: [ConnectListRow], categories: [String], device: ConnectMacSection?, featured: ConnectMacSection?
    ) -> [ConnectMacSection] {
        var result: [ConnectMacSection] = []
        let attention = rows.filter(isAttention)
        if !attention.isEmpty {
            result.append(ConnectMacSection(kind: .needsAttention, title: String(localized: "Needs attention"), rows: attention))
        }
        if let device { result.append(device) }
        if let featured { result.append(featured) }
        let featuredIDs = Set(featured?.rows.map(\.id) ?? [])
        let rest = rows.filter { !isAttention($0) && !featuredIDs.contains($0.id) }
        let extra = Set(rest.map(\.category)).subtracting(categories).sorted()
        for category in categories + extra {
            let inCategory = rest.filter { $0.category == category }
            if !inCategory.isEmpty { result.append(ConnectMacSection(kind: .category(category), title: category, rows: inCategory)) }
        }
        return result
    }
}

public enum ConnectCountLine {
    public static func text(connectors: Int) -> String {
        connectors == 1 ? String(localized: "1 connector") : String(localized: "\(connectors) connectors")
    }
}

public struct ConnectMacNavigation: Equatable, Sendable {
    public enum Screen: Sendable {
        case apps
        case installed
    }

    public enum CancelAction: Sendable {
        case closePanel
        case back
    }

    public private(set) var screen = Screen.apps

    public init() {}

    public mutating func showInstalled() { screen = .installed }

    public mutating func back() { screen = .apps }

    public var showsPanelClose: Bool { screen == .apps }

    public var showsBack: Bool { screen == .installed }

    public var cancelAction: CancelAction { showsBack ? .back : .closePanel }

    public var liveCancelActions: Int { (showsPanelClose ? 1 : 0) + (showsBack ? 1 : 0) }
}
