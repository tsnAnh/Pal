import Foundation

public enum CapabilityGroupKind: Sendable, Hashable, CaseIterable {
    case needsKey
    case on
    case off
}

public struct CapabilityGroup: Sendable, Equatable, Identifiable {
    public let kind: CapabilityGroupKind
    public let rows: [CapabilityRow]

    public var id: CapabilityGroupKind { kind }
}

public extension CapabilityRow {
    var groupKind: CapabilityGroupKind {
        switch indicator {
        case .on: .on
        case .limited: settableKeys.isEmpty ? .on : .needsKey
        case .off: settableKeys.isEmpty ? .off : .needsKey
        case .unavailable: .off
        }
    }
}

public extension Sequence where Element == CapabilityRow {
    var groupedByState: [CapabilityGroup] {
        let rows = Array(self)
        return CapabilityGroupKind.allCases.compactMap { kind in
            let members = rows.filter { $0.groupKind == kind }
            return members.isEmpty ? nil : CapabilityGroup(kind: kind, rows: members)
        }
    }
}
