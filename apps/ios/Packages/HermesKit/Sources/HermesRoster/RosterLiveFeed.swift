import Foundation
import HermesDiagnostics
import HermesProtocol
import HermesTransport

public struct RosterSnapshot: Sendable, Equatable {
    public var profiles: [JSONValue]
    public var live: [String: BotLiveState]
    public var receivedAt: Date
    public var capabilities: RosterCapabilities

    public init(profiles: [JSONValue], live: [String: BotLiveState], receivedAt: Date, capabilities: RosterCapabilities = RosterCapabilities()) {
        self.profiles = profiles
        self.live = live
        self.receivedAt = receivedAt
        self.capabilities = capabilities
    }
}

public enum RosterFeedUpdate: Sendable, Equatable {
    case link(GatewayLink)
    case snapshot(RosterSnapshot)
}

public struct RosterFeedTiming: Sendable {
    public var backoff: [Duration]
    public var offlineAfterFailures: Int
    public var idleRefresh: Duration
    public var busyRefresh: Duration
    public var pingInterval: Duration

    public init(
        backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        offlineAfterFailures: Int = 2,
        idleRefresh: Duration = .seconds(60),
        busyRefresh: Duration = .seconds(3),
        pingInterval: Duration = .seconds(20)
    ) {
        self.backoff = backoff.isEmpty ? [.seconds(1)] : backoff
        self.offlineAfterFailures = offlineAfterFailures
        self.idleRefresh = idleRefresh
        self.busyRefresh = busyRefresh
        self.pingInterval = pingInterval
    }

    public static let standard = RosterFeedTiming()
}

public actor RosterLiveFeed {
    public nonisolated let updates: AsyncStream<RosterFeedUpdate>

    static let changeEvents: Set<String> = ["sessions.changed", "platforms.changed"]

    private let continuation: AsyncStream<RosterFeedUpdate>.Continuation
    private let connect: @Sendable () async throws -> GatewayConnection
    private let onEvent: (@Sendable (GatewayEvent) -> Void)?
    private let timing: RosterFeedTiming
    private let diagnostics: Diagnostics
    private let clock = ContinuousClock()
    private var runTask: Task<Void, Never>?
    private var activeTrigger: AsyncStream<Void>.Continuation?
    private var backoffSleep: Task<Void, Never>?
    private var link: GatewayLink?
    private var busy = false
    private var lastRefresh: ContinuousClock.Instant

    public init(
        connect: @escaping @Sendable () async throws -> GatewayConnection,
        onEvent: (@Sendable (GatewayEvent) -> Void)? = nil,
        timing: RosterFeedTiming = .standard,
        diagnostics: Diagnostics = .silent
    ) {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.connect = connect
        self.onEvent = onEvent
        self.timing = timing
        self.diagnostics = diagnostics
        lastRefresh = clock.now
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        backoffSleep?.cancel()
        continuation.finish()
    }

    public func nudge() {
        activeTrigger?.yield()
        backoffSleep?.cancel()
    }

    private func run() async {
        var attempt = 0
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                let connection = try await connect()
                attempt = 0
                consecutiveFailures = 0
                publish(link: .connected)
                await serve(connection)
                await connection.close()
                if Task.isCancelled { break }
                publish(link: .reconnecting)
            } catch is CancellationError {
                break
            } catch {
                consecutiveFailures += 1
                diagnostics.info("roster", "gateway dial failed: \(Diagnostics.describe(error))")
                publish(link: consecutiveFailures >= timing.offlineAfterFailures ? .offline : .reconnecting)
            }
            if Task.isCancelled { break }
            let delay = timing.backoff[min(attempt, timing.backoff.count - 1)]
            attempt += 1
            let sleeper = Task<Void, Never> { try? await Task.sleep(for: delay) }
            backoffSleep = sleeper
            await sleeper.value
            backoffSleep = nil
        }
    }

    private func serve(_ connection: GatewayConnection) async {
        let (triggers, trigger) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        activeTrigger = trigger
        busy = false
        lastRefresh = clock.now
        trigger.yield()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.pump(connection.events, into: trigger, observer: self.onEvent) }
            group.addTask { await self.keepAlive(connection) }
            group.addTask { await self.refreshLoop(connection, triggers) }
            group.addTask { await self.ticker(trigger) }
            await group.next()
            group.cancelAll()
        }
        trigger.finish()
        activeTrigger = nil
    }

    private static func pump(
        _ events: AsyncStream<GatewayEvent>,
        into trigger: AsyncStream<Void>.Continuation,
        observer: (@Sendable (GatewayEvent) -> Void)?
    ) async {
        for await event in events {
            observer?(event)
            if changeEvents.contains(event.type) { trigger.yield() }
        }
    }

    private func keepAlive(_ connection: GatewayConnection) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: timing.pingInterval)
            if Task.isCancelled { return }
            do {
                try await connection.ping()
            } catch is CancellationError {
                return
            } catch {
                diagnostics.info("roster", "gateway ping failed: \(Diagnostics.describe(error))")
                await connection.abort()
                return
            }
        }
    }

    private func ticker(_ trigger: AsyncStream<Void>.Continuation) async {
        let tick = min(timing.busyRefresh, .seconds(1))
        while !Task.isCancelled {
            do { try await Task.sleep(for: tick) } catch { return }
            let interval = busy ? timing.busyRefresh : timing.idleRefresh
            if clock.now - lastRefresh >= interval { trigger.yield() }
        }
    }

    private func refreshLoop(_ connection: GatewayConnection, _ triggers: AsyncStream<Void>) async {
        for await _ in triggers {
            if Task.isCancelled { return }
            await refresh(connection)
        }
    }

    private func refresh(_ connection: GatewayConnection) async {
        do {
            let snapshot = try await RosterSnapshotFetcher.fetch(on: connection)
            busy = snapshot.live.values.contains { state in
                state.sessions.contains { $0 == .working || $0 == .starting || $0 == .waiting }
            }
            lastRefresh = clock.now
            continuation.yield(.snapshot(snapshot))
        } catch is CancellationError {
            return
        } catch GatewayTransportError.rpc(let error) {
            diagnostics.warning("roster", "profiles.list refused: \(Diagnostics.describe(error))")
            lastRefresh = clock.now
        } catch {
            diagnostics.info("roster", "refresh failed, dropping socket: \(Diagnostics.describe(error))")
            await connection.abort()
        }
    }

    private func publish(link next: GatewayLink) {
        guard link != next else { return }
        link = next
        continuation.yield(.link(next))
    }
}
