import Foundation
import Observation
import PalProtocol

public struct SlackBot: Sendable, Identifiable {
    public var name: String
    public var displayName: String
    public var client: any ChatInstallClient

    public var id: String { name }

    public init(name: String, displayName: String, client: any ChatInstallClient) {
        self.name = name
        self.displayName = displayName
        self.client = client
    }
}

public enum SlackBotState: Sendable, Equatable {
    case notInstalled
    case connected(workspace: String)
    case needsReinstall(workspace: String)
    case unavailable(ChatInstallClientError)

    public init(_ result: ChatInstallStatusResult) {
        guard result.state.step == .ready, let installation = result.installation else {
            self = .notInstalled
            return
        }
        switch installation.status {
        case .active: self = .connected(workspace: installation.workspaceName)
        case .needsReauth: self = .needsReinstall(workspace: installation.workspaceName)
        case .revoked, .unknown: self = .notInstalled
        }
    }

    public var isInstalled: Bool {
        switch self {
        case .connected, .needsReinstall: true
        case .notInstalled, .unavailable: false
        }
    }

    public var detail: String {
        switch self {
        case .notInstalled: String(localized: "Not installed")
        case .connected(let workspace): String(localized: "Connected to \(workspace)")
        case .needsReinstall: String(localized: "Needs reinstall for a new permission")
        case .unavailable: String(localized: "Couldn't check")
        }
    }
}

public struct SlackBotRow: Sendable, Equatable, Identifiable {
    public var name: String
    public var displayName: String
    public var state: SlackBotState

    public var id: String { name }
}

@MainActor
@Observable
public final class SlackBotsModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case failed(ChatInstallClientError)
    }

    public static let provider = "slack"

    public private(set) var rows: [SlackBotRow]
    public private(set) var phase: Phase = .loading
    private let bots: [SlackBot]

    public init(bots: [SlackBot]) {
        self.bots = bots
        rows = bots.map { SlackBotRow(name: $0.name, displayName: $0.displayName, state: .notInstalled) }
    }

    public var installedCount: Int { rows.filter(\.state.isInstalled).count }

    public var needsReinstall: Bool {
        rows.contains { if case .needsReinstall = $0.state { true } else { false } }
    }

    public var summary: String {
        switch phase {
        case .loading: String(localized: "Checking")
        case .failed: String(localized: "Couldn't check")
        case .ready:
            switch installedCount {
            case 0: String(localized: "Not set up")
            case 1: String(localized: "Connected for 1 bot")
            case let count: String(localized: "Connected for \(count) bots")
            }
        }
    }

    public func load() async {
        let scope = ChatInstallScope(provider: Self.provider, workspace: "")
        let outcomes = await withTaskGroup(of: (Int, Result<SlackBotState, ChatInstallClientError>).self) { group in
            for (index, bot) in bots.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(SlackBotState(try await bot.client.status(scope))))
                    } catch {
                        return (index, .failure(ChatInstallClientError(error)))
                    }
                }
            }
            var collected: [Int: Result<SlackBotState, ChatInstallClientError>] = [:]
            for await (index, outcome) in group { collected[index] = outcome }
            return collected
        }
        guard !Task.isCancelled else { return }
        rows = bots.enumerated().map { index, bot in
            let state: SlackBotState
            switch outcomes[index] {
            case .success(let known)?: state = known
            case .failure(let error)?: state = .unavailable(error)
            case nil: state = .notInstalled
            }
            return SlackBotRow(name: bot.name, displayName: bot.displayName, state: state)
        }
        let failures = outcomes.values.compactMap { outcome -> ChatInstallClientError? in
            if case .failure(let error) = outcome { error } else { nil }
        }
        if !bots.isEmpty, failures.count == bots.count, let first = failures.first {
            phase = .failed(first)
        } else {
            phase = .ready
        }
    }
}
