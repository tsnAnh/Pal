import Foundation
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization

final class DeferredConnectorsAPI: DeviceConnectorsAPI {
    private let target = Mutex<(any DeviceConnectorsAPI)?>(nil)

    func bind(_ api: any DeviceConnectorsAPI) { target.withLock { $0 = api } }

    private func bound() throws -> any DeviceConnectorsAPI {
        guard let api = target.withLock({ $0 }) else { throw DeviceToolHostError.offline }
        return api
    }

    func list() async throws -> DeviceConnectorsResult { try await bound().list() }

    func set(_ id: DeviceConnectorID, state: DeviceConnectorState?, osPermission: DeviceOSPermission?) async throws -> DeviceConnectorsResult {
        try await bound().set(id, state: state, osPermission: osPermission)
    }
}

public struct DeviceToolStack: Sendable {
    public let host: DeviceToolHost
    public let ledger: ConnectorLedger
    public let executor: DeviceToolExecutor

    public static func make(
        connect: @escaping DeviceToolHost.Connect,
        providers: DeviceProviders,
        permissions: any DevicePermissions,
        consent: any ConsentPrompting,
        environment: DeviceToolEnvironment = DeviceToolEnvironment(),
        timing: DeviceToolHostTiming = .standard,
        diagnostics: Diagnostics = .silent
    ) -> DeviceToolStack {
        let deferred = DeferredConnectorsAPI()
        let ledger = ConnectorLedger(api: deferred)
        let executor = DeviceToolExecutor(providers: providers, permissions: permissions, ledger: ledger, consent: consent, environment: environment)
        let host = DeviceToolHost(connect: connect, executor: executor, ledger: ledger, timing: timing, diagnostics: diagnostics)
        deferred.bind(host.connectors)
        return DeviceToolStack(host: host, ledger: ledger, executor: executor)
    }
}
