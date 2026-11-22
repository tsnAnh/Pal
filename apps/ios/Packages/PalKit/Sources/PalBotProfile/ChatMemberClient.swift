import Foundation
import PalProtocol

public struct ChatAudienceChange: Sendable, Hashable {
    public var policy: ChatAudiencePolicy
    public var members: [String]?
    public var includeRestricted: Bool?
    public var expectedRevision: Int

    public init(policy: ChatAudiencePolicy, members: [String]? = nil, includeRestricted: Bool? = nil, expectedRevision: Int) {
        self.policy = policy
        self.members = members
        self.includeRestricted = includeRestricted
        self.expectedRevision = expectedRevision
    }
}

public protocol ChatMemberClient: Sendable {
    func audience(_ scope: ChatInstallScope) async throws -> ChatAudienceWire
    func setAudience(_ scope: ChatInstallScope, _ change: ChatAudienceChange) async throws -> ChatAudienceWire
    func people(_ scope: ChatInstallScope, query: String, cursor: String?) async throws -> ChatPeoplePageWire
    func report(_ scope: ChatInstallScope) async throws -> ChatReportDestinationWire
    func setReport(_ scope: ChatInstallScope, _ destination: ChatReportDestinationWire) async throws -> ChatReportDestinationWire
    func leave(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceLeaveOutcome
    func desk() async throws -> [ChatDeskItemWire]
    func decide(itemId: String, choice: ChatDeskChoice, expectedRevision: Int) async throws -> ChatDeskItemWire
}
