import Foundation
import HermesProtocol

public protocol DeviceConnectorsAPI: Sendable {
    func list() async throws -> DeviceConnectorsResult
    func set(_ id: DeviceConnectorID, state: DeviceConnectorState?, osPermission: DeviceOSPermission?) async throws -> DeviceConnectorsResult
}

public actor ConnectorLedger {
    private let api: any DeviceConnectorsAPI
    private var statuses: [DeviceConnectorID: DeviceConnectorStatus] = [:]
    private var loaded = false
    private var observers: [UUID: @Sendable ([DeviceConnectorStatus]) -> Void] = [:]

    public init(api: any DeviceConnectorsAPI) {
        self.api = api
    }

    public var snapshot: [DeviceConnectorStatus] {
        DeviceConnectorID.allCases.compactMap { statuses[$0] }
    }

    public var isLoaded: Bool { loaded }

    public func state(for id: DeviceConnectorID) -> DeviceConnectorState? {
        statuses[id]?.state
    }

    public func osPermission(for id: DeviceConnectorID) -> DeviceOSPermission? {
        statuses[id]?.osPermission
    }

    public func observe(_ observer: @escaping @Sendable ([DeviceConnectorStatus]) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        if loaded { observer(snapshot) }
        return token
    }

    public func stopObserving(_ token: UUID) {
        observers[token] = nil
    }

    @discardableResult
    public func refresh() async throws -> [DeviceConnectorStatus] {
        apply(try await api.list())
        return snapshot
    }

    @discardableResult
    public func set(_ id: DeviceConnectorID, state: DeviceConnectorState? = nil, osPermission: DeviceOSPermission? = nil) async throws -> [DeviceConnectorStatus] {
        apply(try await api.set(id, state: state, osPermission: osPermission))
        return snapshot
    }

    public func reportOSPermission(_ permission: DeviceOSPermission, for id: DeviceConnectorID) async {
        guard statuses[id]?.osPermission != permission else { return }
        _ = try? await set(id, osPermission: permission)
    }

    private func apply(_ result: DeviceConnectorsResult) {
        statuses = Dictionary(result.connectors.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        loaded = true
        let current = snapshot
        for observer in observers.values { observer(current) }
    }
}
