import Foundation
import PalDiagnostics
import PalProtocol

public actor WarmSessionPool {
    public static let defaultLimit = 3

    private let limit: Int
    private var idle: [SessionHub] = []

    public init(limit: Int = WarmSessionPool.defaultLimit) {
        self.limit = limit
    }

    func park(_ hub: SessionHub) async {
        idle.removeAll { $0 === hub }
        idle.append(hub)
        while idle.count > limit {
            let oldest = idle.removeFirst()
            await oldest.coolDown()
        }
    }

    func unpark(_ hub: SessionHub) {
        idle.removeAll { $0 === hub }
    }
}

public actor SessionHub: OutboxSubmitter {
    public static let warmWindow = Duration.seconds(120)

    private let profile: String
    private let connector: any ChatConnector
    private let store: (any TimelineStore)?
    private let pool: WarmSessionPool?
    private let warmWindow: Duration
    private let diagnostics: Diagnostics
    private var current: ChatSession?
    private var holders = 0
    private var coolDownTask: Task<Void, Never>?

    public init(
        profile: String,
        connector: any ChatConnector,
        store: (any TimelineStore)? = nil,
        pool: WarmSessionPool? = nil,
        warmWindow: Duration = SessionHub.warmWindow,
        diagnostics: Diagnostics = .silent
    ) {
        self.profile = profile
        self.connector = connector
        self.store = store
        self.pool = pool
        self.warmWindow = warmWindow
        self.diagnostics = diagnostics
    }

    public func acquire() async -> ChatSession {
        holders += 1
        coolDownTask?.cancel()
        coolDownTask = nil
        let session = current ?? ChatSession(profile: profile, connector: connector, store: store, diagnostics: diagnostics)
        current = session
        await session.setWatching(true)
        await pool?.unpark(self)
        return session
    }

    public func release(_ session: ChatSession) async {
        guard session === current, holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        await session.flushCache()
        await session.setWatching(false)
        guard let pool else {
            await coolDown()
            return
        }
        coolDownTask = Task { [weak self, warmWindow] in
            try? await Task.sleep(for: warmWindow)
            guard !Task.isCancelled else { return }
            await self?.coolDown()
        }
        await pool.park(self)
    }

    func coolDown() async {
        guard holders == 0, let session = current else { return }
        coolDownTask?.cancel()
        coolDownTask = nil
        current = nil
        await pool?.unpark(self)
        await session.close()
    }

    public func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        guard let current else { throw ChatError.notConnected }
        return try await current.submit(entry, files: files)
    }
}
