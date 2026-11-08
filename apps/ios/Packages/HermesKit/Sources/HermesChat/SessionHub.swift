import Foundation
import HermesDiagnostics
import HermesProtocol

public actor SessionHub: OutboxSubmitter {
    private let profile: String
    private let connector: any ChatConnector
    private let diagnostics: Diagnostics
    private var current: ChatSession?
    private var holders = 0

    public init(profile: String, connector: any ChatConnector, diagnostics: Diagnostics = .silent) {
        self.profile = profile
        self.connector = connector
        self.diagnostics = diagnostics
    }

    public func acquire() -> ChatSession {
        holders += 1
        if let current { return current }
        let session = ChatSession(profile: profile, connector: connector, diagnostics: diagnostics)
        current = session
        return session
    }

    public func release(_ session: ChatSession) async {
        guard session === current, holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        current = nil
        await session.close()
    }

    public func submit(_ entry: OutboxEntry, files: [OutgoingFile]) async throws -> AdmissionStatus {
        guard let current else { throw ChatError.notConnected }
        return try await current.submit(entry, files: files)
    }
}
