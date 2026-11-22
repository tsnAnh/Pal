import Foundation
import Observation
import PalProtocol

@MainActor
@Observable
public final class ChatMembersModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed(ChatInstallClientError)
    }

    public enum Notice: Hashable, Sendable {
        case changedElsewhere
        case notSaved
        case offline
        case notJoined
    }

    public private(set) var phase = Phase.loading
    public private(set) var audience: ChatAudienceWire?
    public private(set) var report: ChatReportDestinationWire?
    public private(set) var notice: Notice?
    public private(set) var isSaving = false

    private let client: any ChatMemberClient
    private var scope: ChatInstallScope?

    public init(client: any ChatMemberClient) {
        self.client = client
    }

    public func load(scope: ChatInstallScope) async {
        self.scope = scope
        if audience == nil { phase = .loading }
        do {
            async let loadedAudience = client.audience(scope)
            async let loadedReport = client.report(scope)
            let (fresh, destination) = try await (loadedAudience, loadedReport)
            audience = fresh
            report = destination
            phase = .ready
        } catch is CancellationError {
        } catch {
            if audience == nil { phase = .failed(ChatInstallClientError(error)) } else { notice = Self.notice(for: error) }
        }
    }

    public func reload() async {
        guard let scope else { return }
        await load(scope: scope)
    }

    public func dismissNotice() { notice = nil }

    public func setPolicy(_ policy: ChatAudiencePolicy) async {
        await change { ChatAudienceChange(policy: policy, expectedRevision: $0.revision) }
    }

    public func setMembers(_ ids: [String]) async {
        await change { ChatAudienceChange(policy: .listed, members: ids, expectedRevision: $0.revision) }
    }

    public func removeMember(_ id: String) async {
        let remaining = (audience?.members ?? []).map(\.id).filter { $0 != id }
        await setMembers(remaining)
    }

    public func setIncludeRestricted(_ include: Bool) async {
        await change { ChatAudienceChange(policy: $0.policy, includeRestricted: include, expectedRevision: $0.revision) }
    }

    public func setReport(_ destination: ChatReportDestinationWire) async {
        guard let scope, !isSaving else { return }
        isSaving = true
        notice = nil
        defer { isSaving = false }
        do {
            report = try await client.setReport(scope, destination)
        } catch is CancellationError {
        } catch {
            notice = Self.notice(for: error)
        }
    }

    public func leave(_ spaceId: String) async -> Bool {
        guard let scope, !isSaving else { return false }
        isSaving = true
        notice = nil
        defer { isSaving = false }
        do {
            let outcome = try await client.leave(scope, spaceId: spaceId)
            if report?.spaceId == spaceId { report = .ownerDirectMessages }
            return outcome == .left || outcome == .notMember
        } catch is CancellationError {
            return false
        } catch {
            notice = Self.notice(for: error)
            return false
        }
    }

    public func people(query: String, cursor: String?) async throws -> ChatPeoplePageWire {
        guard let scope else { throw ChatInstallClientError.failed(.gateway) }
        return try await client.people(scope, query: query, cursor: cursor)
    }

    private func change(_ build: (ChatAudienceWire) -> ChatAudienceChange) async {
        guard let scope, let current = audience, !isSaving else { return }
        isSaving = true
        notice = nil
        defer { isSaving = false }
        do {
            audience = try await client.setAudience(scope, build(current))
        } catch is CancellationError {
        } catch ChatInstallClientError.staleRevision {
            await reload()
            notice = .changedElsewhere
        } catch {
            notice = Self.notice(for: error)
        }
    }

    private static func notice(for error: any Error) -> Notice {
        let known = ChatInstallClientError(error)
        if known == .notJoined { return .notJoined }
        return known.isUnreachable ? .offline : .notSaved
    }
}
