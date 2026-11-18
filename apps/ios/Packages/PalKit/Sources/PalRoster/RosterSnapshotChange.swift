import Foundation
import Observation

public struct RosterSnapshotChange: Sendable, Equatable {
    public let profiles: Bool
    public let live: Bool
    public let capabilities: Bool

    public init(from previous: RosterSnapshot?, to next: RosterSnapshot) {
        profiles = previous?.profiles != next.profiles
        live = previous?.live != next.live
        capabilities = previous?.capabilities != next.capabilities
    }

    public var isEmpty: Bool { !profiles && !live && !capabilities }
}

extension Observable where Self: AnyObject {
    @discardableResult
    public func assignIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Self, Value>,
        _ value: Value,
        force: Bool = false
    ) -> Bool {
        guard force || self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }
}
