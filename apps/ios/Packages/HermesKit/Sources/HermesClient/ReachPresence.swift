import Foundation
import HermesAuth
import HermesDiagnostics
import HermesProtocol
import HermesTransport
import Synchronization

public actor ReachPresence {
    public nonisolated let offers: AsyncStream<ReachOffer>

    private struct Route {
        weak var connection: GatewayConnection?
        let acceptsOffers: Bool
        var delivered: ReachAttention
    }

    private static let callTimeout = Duration.seconds(10)

    private let identity: DeviceIdentity
    private let diagnostics: Diagnostics
    private let offerContinuation: AsyncStream<ReachOffer>.Continuation
    private nonisolated let ledger = Mutex(OfferLedger(capacity: 256))
    private var attention: ReachAttention
    private var routes: [Route] = []
    private var flushing = false
    private var reported: [String: ReachOutcome] = [:]
    private var push: PushRegistration?

    public init(identity: DeviceIdentity, attention: ReachAttention = .foreground, diagnostics: Diagnostics = .silent) {
        self.identity = identity
        self.attention = attention
        self.diagnostics = diagnostics
        (offers, offerContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public var currentAttention: ReachAttention { attention }

    public var canPresentOffers: Bool { attention == .foreground }

    public func declare(on connection: GatewayConnection, acceptsOffers: Bool) async {
        let declared = attention
        do {
            let result = try await connection.call(
                "client.hello",
                params: ReachWire.helloParams(identity: identity, acceptsOffers: acceptsOffers, attention: declared),
                timeout: Self.callTimeout
            )
            guard result["recorded"]?.boolValue == true else {
                diagnostics.info("reach", "client.hello was not recorded")
                return
            }
        } catch is CancellationError {
            return
        } catch {
            diagnostics.info("reach", "client.hello refused: \(Diagnostics.describe(error))")
            return
        }
        routes.removeAll { $0.connection == nil || $0.connection === connection }
        routes.append(Route(connection: connection, acceptsOffers: acceptsOffers, delivered: declared))
        await registerPush(on: connection)
        await flush()
    }

    public func setPushRegistration(_ registration: PushRegistration?) async {
        guard registration != push else { return }
        push = registration
        for connection in routes.compactMap(\.connection) { await registerPush(on: connection) }
    }

    public func unregisterPush() async {
        push = nil
        for connection in routes.compactMap(\.connection) {
            do {
                _ = try await connection.call(
                    "push.unregister",
                    params: PushWire.unregisterParams(deviceID: identity.deviceID),
                    timeout: Self.callTimeout
                )
            } catch is CancellationError {
                return
            } catch {
                diagnostics.info("push", "push.unregister failed: \(Diagnostics.describe(error))")
            }
        }
    }

    private func registerPush(on connection: GatewayConnection) async {
        guard let push else { return }
        do {
            let result = try await connection.call(
                "push.register",
                params: PushWire.registerParams(deviceID: identity.deviceID, registration: push),
                timeout: Self.callTimeout
            )
            if result["push_enabled"]?.boolValue == false {
                diagnostics.info("push", "registered; the gateway has no push credentials yet")
            }
        } catch is CancellationError {
            return
        } catch {
            diagnostics.info("push", "push.register failed: \(Diagnostics.describe(error))")
        }
    }

    public func setAttention(_ next: ReachAttention) async {
        guard next != attention else { return }
        attention = next
        await flush()
    }

    public nonisolated func receive(_ event: GatewayEvent) {
        guard let offer = ReachOffer(event: event) else { return }
        guard ledger.withLock({ $0.admit(offer.offerID) }) else { return }
        offerContinuation.yield(offer)
    }

    @discardableResult
    public func report(_ outcome: ReachOutcome, for offerID: String) async -> Bool {
        if let previous = reported[offerID], previous == outcome || previous.isTerminal { return false }
        reported[offerID] = outcome
        for index in routes.indices.reversed() where routes[index].acceptsOffers {
            guard let connection = routes[index].connection else { continue }
            do {
                _ = try await connection.call(
                    "reach.outcome",
                    params: ReachWire.outcomeParams(offerID: offerID, outcome: outcome),
                    timeout: Self.callTimeout
                )
                return true
            } catch is CancellationError {
                return false
            } catch {
                diagnostics.info("reach", "reach.outcome \(outcome.rawValue) failed: \(Diagnostics.describe(error))")
            }
        }
        return false
    }

    private func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let index = routes.firstIndex(where: { $0.connection != nil && $0.delivered != attention }) {
            let target = attention
            guard let connection = routes[index].connection else { continue }
            do {
                _ = try await connection.call("client.attention", params: ReachWire.attentionParams(target), timeout: Self.callTimeout)
                updateDelivered(connection, to: target)
            } catch GatewayTransportError.closed {
                routes.removeAll { $0.connection === connection }
            } catch {
                diagnostics.info("reach", "client.attention failed: \(Diagnostics.describe(error))")
                updateDelivered(connection, to: target)
            }
        }
        routes.removeAll { $0.connection == nil }
    }

    private func updateDelivered(_ connection: GatewayConnection, to state: ReachAttention) {
        for index in routes.indices where routes[index].connection === connection {
            routes[index].delivered = state
        }
    }
}
