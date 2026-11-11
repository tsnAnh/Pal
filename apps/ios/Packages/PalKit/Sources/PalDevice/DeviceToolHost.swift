import Foundation
import PalDiagnostics
import PalProtocol
import PalTransport

public enum DeviceToolHostError: Error, Sendable, Equatable {
    case offline
    case malformedReply
}

public struct DeviceToolHostTiming: Sendable {
    public var backoff: [Duration]
    public var pingInterval: Duration
    public var callTimeout: Duration
    public var connectWait: Duration

    public init(
        backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30)],
        pingInterval: Duration = .seconds(25),
        callTimeout: Duration = .seconds(15),
        connectWait: Duration = .seconds(12)
    ) {
        self.backoff = backoff
        self.pingInterval = pingInterval
        self.callTimeout = callTimeout
        self.connectWait = connectWait
    }

    public static let standard = DeviceToolHostTiming()
}

public actor DeviceToolHost {
    public typealias Connect = @Sendable () async throws -> GatewayConnection

    private static let answeredCapacity = 128

    private let connect: Connect
    private let executor: DeviceToolExecutor
    private let ledger: ConnectorLedger
    private let timing: DeviceToolHostTiming
    private let diagnostics: Diagnostics
    private var runTask: Task<Void, Never>?
    private var connection: GatewayConnection?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var answered: [String] = []

    public init(
        connect: @escaping Connect,
        executor: DeviceToolExecutor,
        ledger: ConnectorLedger,
        timing: DeviceToolHostTiming = .standard,
        diagnostics: Diagnostics = .silent
    ) {
        self.connect = connect
        self.executor = executor
        self.ledger = ledger
        self.timing = timing
        self.diagnostics = diagnostics
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        cancelAll()
        let closing = connection
        connection = nil
        await closing?.close()
    }

    public var isConnected: Bool { connection != nil }

    public func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timing.connectWait
        while connection == nil {
            guard ContinuousClock.now < deadline, runTask != nil else { throw DeviceToolHostError.offline }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let connection else { throw DeviceToolHostError.offline }
        return try await connection.call(method, params: params, timeout: timing.callTimeout)
    }

    public nonisolated var connectors: any DeviceConnectorsAPI { HostConnectorsAPI(host: self) }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let fresh = try await connect()
                connection = fresh
                attempt = 0
                await serve(fresh)
                connection = nil
                cancelAll()
                await fresh.close()
            } catch is CancellationError {
                break
            } catch {
                diagnostics.info("device", "host dial failed: \(Diagnostics.describe(error))")
            }
            if Task.isCancelled { break }
            let delay = timing.backoff[min(attempt, timing.backoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
        connection = nil
    }

    private func serve(_ live: GatewayConnection) async {
        _ = try? await ledger.refresh()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await event in live.events { await self?.handle(event, on: live) }
            }
            group.addTask { [timing, diagnostics] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: timing.pingInterval)
                    if Task.isCancelled { return }
                    do { try await live.ping() } catch is CancellationError { return } catch {
                        diagnostics.info("device", "host ping failed: \(Diagnostics.describe(error))")
                        await live.abort()
                        return
                    }
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func handle(_ event: GatewayEvent, on live: GatewayConnection) {
        if let request = DeviceToolRequest(event: event) {
            accept(request, on: live)
        } else if let cancel = DeviceToolCancel(event: event) {
            inFlight.removeValue(forKey: cancel.requestID)?.cancel()
        }
    }

    private func accept(_ request: DeviceToolRequest, on live: GatewayConnection) {
        guard inFlight[request.requestID] == nil, !answered.contains(request.requestID) else { return }
        let executor = executor
        diagnostics.info("device", "device.tool.request \(request.action) consent=\(request.needsConsent)")
        let task = Task { [weak self] in
            let outcome = await executor.execute(request)
            guard !Task.isCancelled else { return }
            await self?.respond(outcome, to: request, on: live)
        }
        inFlight[request.requestID] = task
    }

    private func respond(_ outcome: DeviceToolOutcome, to request: DeviceToolRequest, on live: GatewayConnection) async {
        guard inFlight.removeValue(forKey: request.requestID) != nil else { return }
        answered.append(request.requestID)
        if answered.count > Self.answeredCapacity { answered.removeFirst() }
        diagnostics.info("device", "device.tool.respond \(request.action) \(Self.summary(of: outcome))")
        do {
            _ = try await live.call("device.tool.respond", params: outcome.respondParams(requestID: request.requestID), timeout: timing.callTimeout)
        } catch {
            diagnostics.info("device", "device.tool.respond failed: \(Diagnostics.describe(error))")
        }
    }

    private static func summary(of outcome: DeviceToolOutcome) -> String {
        switch outcome {
        case .success: "ok"
        case .failure(let code, _): code.rawValue
        }
    }

    private func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }
}

struct HostConnectorsAPI: DeviceConnectorsAPI {
    let host: DeviceToolHost

    func list() async throws -> DeviceConnectorsResult {
        try Self.decode(try await host.call("device_connectors.list", [:]))
    }

    func set(_ id: DeviceConnectorID, state: DeviceConnectorState?, osPermission: DeviceOSPermission?) async throws -> DeviceConnectorsResult {
        try Self.decode(try await host.call("device_connectors.set", DeviceWire.setConnectorParams(id, state: state, osPermission: osPermission)))
    }

    private static func decode(_ value: JSONValue) throws -> DeviceConnectorsResult {
        do { return try value.decoded(as: DeviceConnectorsResult.self) } catch { throw DeviceToolHostError.malformedReply }
    }
}
