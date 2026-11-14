import Foundation
import PalChat
import PalProtocol
import PalTransport
import Observation

struct BotThreadRoute: Hashable {
    let botName: String
    let threadID: String
    let focusExchangeID: String?
}

enum BotThreadLoadState: Equatable {
    case loading
    case ready
    case failed
}

@MainActor
@Observable
final class BotThreadModel {
    private(set) var timeline: BotThreadTimeline
    private(set) var state: BotThreadLoadState = .loading
    private(set) var isLoadingOlder = false
    private(set) var isLoadingNewer = false
    private(set) var focusRequest: String?

    let route: BotThreadRoute
    let roster: RosterModel

    private let connectionModel: ConnectionModel
    private var api: SessionAPI?
    private var runner: Task<Void, Never>?
    private var openedWithFocus = false

    init(route: BotThreadRoute, connection: ConnectionModel, roster: RosterModel) {
        self.route = route
        connectionModel = connection
        self.roster = roster
        timeline = BotThreadTimeline(threadID: route.threadID)
        if route.focusExchangeID == nil, let held = connection.surfaces.remembered(BotThreadTimeline.self, surfaceKey) {
            timeline = held
        }
    }

    private var surfaceKey: SurfaceKey { .screen("bot-thread-\(route.threadID)", bot: route.botName) }

    var avatars: ParticipantAvatars { ParticipantAvatars(roster: roster) }

    var owner: BotThreadParticipant? { timeline.participants.first { $0.isSelf } }
    var counterpart: BotThreadParticipant? { timeline.participants.first { !$0.isSelf } }

    func start() {
        guard runner == nil, let connector = connectionModel.chatConnector else { return }
        runner = Task { await self.run(connector) }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        api = nil
    }

    func consumeFocusRequest() {
        focusRequest = nil
    }

    func loadOlder() {
        guard let api, let cursor = timeline.olderCursor, !isLoadingOlder else { return }
        isLoadingOlder = true
        Task {
            defer { isLoadingOlder = false }
            guard let page = try? await api.botThreadRead(threadID: route.threadID, mode: .before(cursor)) else { return }
            timeline.apply(older: page)
        }
    }

    func loadNewer() {
        guard let api, let cursor = timeline.newerCursor, !isLoadingNewer else { return }
        isLoadingNewer = true
        Task {
            defer { isLoadingNewer = false }
            guard let page = try? await api.botThreadRead(threadID: route.threadID, mode: .after(cursor)) else { return }
            timeline.apply(newer: page)
        }
    }

    private func run(_ connector: PalClientConnector) async {
        var delay = Duration.milliseconds(500)
        while !Task.isCancelled {
            do {
                let connection = try await connector.connect()
                let api = SessionAPI(connection: connection, profile: route.botName)
                defer { Task { await connection.close() } }
                try await catchUp(api)
                self.api = api
                delay = .milliseconds(500)
                for await event in connection.events where event.type == "bot_threads.changed" {
                    try await catchUp(api)
                }
            } catch is CancellationError {
                return
            } catch {
                if state == .loading, error.isNotFound {
                    state = .failed
                    return
                }
            }
            api = nil
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }
    }

    private func catchUp(_ api: SessionAPI) async throws {
        if state == .ready {
            let page = try await api.botThreadRead(threadID: route.threadID, mode: .sinceRevision(timeline.revision))
            timeline.apply(delta: page)
            if route.focusExchangeID == nil { connectionModel.surfaces.remember(timeline, surfaceKey) }
        } else {
            let mode: BotThreadReadMode = route.focusExchangeID.map { .focus(exchangeID: $0) } ?? .newest
            let page = try await api.botThreadRead(threadID: route.threadID, mode: mode)
            timeline.apply(initial: page)
            state = .ready
            if route.focusExchangeID == nil { connectionModel.surfaces.remember(timeline, surfaceKey) }
            if !openedWithFocus {
                openedWithFocus = true
                focusRequest = timeline.focusMessageID ?? timeline.messages.last?.id
            }
        }
    }
}

private extension Error {
    var isNotFound: Bool {
        guard let transport = self as? GatewayTransportError, case .rpc(let rpc) = transport else { return false }
        return rpc.data?["reason"]?.stringValue == "not_found" || rpc.message == "not_found"
    }
}
