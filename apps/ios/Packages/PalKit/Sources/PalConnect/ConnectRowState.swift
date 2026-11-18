import Foundation

public enum ConnectBotInstall: Sendable, Equatable {
    case notInstalled
    case installed(summary: String)
    case needsReinstall(summary: String)
}

public enum ConnectRowState: Sendable, Equatable {
    case connect
    case setUp
    case connected
    case needsAttention(reason: String)
    case waiting(reason: String)
    case unavailable

    public var actionTitle: String? {
        switch self {
        case .connect: String(localized: "Connect")
        case .setUp: String(localized: "Set up")
        case .connected: String(localized: "Connected")
        case .needsAttention: String(localized: "Reconnect")
        case .waiting, .unavailable: nil
        }
    }

    public static let expiredSignIn = String(localized: "Sign-in expired")
}

public struct ConnectRowInput: Sendable, Equatable {
    public var connection: ConnectAppState
    public var isBusy: Bool
    public var authReason: String?
    public var needsGuidedSetup: Bool
    public var hasSetupFlow: Bool
    public var bot: ConnectBotInstall?

    public init(
        connection: ConnectAppState, isBusy: Bool = false, authReason: String? = nil, needsGuidedSetup: Bool = false,
        hasSetupFlow: Bool = false, bot: ConnectBotInstall? = nil
    ) {
        self.connection = connection
        self.isBusy = isBusy
        self.authReason = authReason
        self.needsGuidedSetup = needsGuidedSetup
        self.hasSetupFlow = hasSetupFlow
        self.bot = bot
    }

    public init(app: ConnectApp, isBusy: Bool = false, bot: ConnectBotInstall? = nil) {
        self.init(
            connection: app.state, isBusy: isBusy, authReason: app.authReason,
            needsGuidedSetup: app.oauthClientEntry == nil && app.setupGuideEntry != nil,
            hasSetupFlow: app.oauthClientEntry != nil || app.setupGuideEntry != nil || bot != nil, bot: bot
        )
    }
}

extension ConnectRowState {
    public static func resolve(_ input: ConnectRowInput) -> ConnectRowState {
        if input.isBusy { return .waiting(reason: String(localized: "Working…")) }
        if let bot = input.bot {
            switch bot {
            case .notInstalled: return .setUp
            case .installed: return .connected
            case .needsReinstall(let summary): return .needsAttention(reason: summary)
            }
        }
        switch input.connection {
        case .connected: return .connected
        case .needsAuthorization: return .needsAttention(reason: ConnectorCardState.cleaned(input.authReason) ?? expiredSignIn)
        case .needsSetup: return input.hasSetupFlow ? .setUp : .unavailable
        case .disconnected: return input.needsGuidedSetup ? .setUp : .connect
        }
    }
}

public struct ConnectListRow: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var state: ConnectRowState
    public var summary: String
    public var hasProblem: Bool

    public init(app: ConnectApp, state: ConnectRowState, problem: String? = nil, botSummary: String? = nil) {
        id = app.id
        name = app.name
        category = app.category
        self.state = state
        let note = ConnectorCardState.cleaned(app.summary)
        let issue = ConnectorCardState.cleaned(problem)
        switch state {
        case .connect:
            summary = issue ?? note ?? String(localized: "Sign in with your account")
        case .setUp:
            summary = botSummary ?? String(localized: "One-time setup, about 5 minutes")
        case .connected:
            summary = botSummary ?? String(localized: "Connected")
        case .needsAttention(let reason), .waiting(let reason):
            summary = reason
        case .unavailable:
            summary = note ?? String(localized: "Not available yet")
        }
        if case .needsAttention = state {
            hasProblem = true
        } else {
            hasProblem = issue != nil && state == .connect
        }
    }
}

public struct ConnectListSection: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case needsAttention
        case connected
        case category(String)
    }

    public var kind: Kind
    public var rows: [ConnectListRow]

    public var id: String {
        switch kind {
        case .needsAttention: "needs-attention"
        case .connected: "connected"
        case .category(let name): "category-\(name)"
        }
    }

    public var title: String {
        switch kind {
        case .needsAttention: String(localized: "Needs attention")
        case .connected: String(localized: "Connected")
        case .category(let name): name
        }
    }
}

public enum ConnectListLayout {
    public static func sections(rows: [ConnectListRow], categories: [String]) -> [ConnectListSection] {
        var result: [ConnectListSection] = []
        let attention = rows.filter { if case .needsAttention = $0.state { true } else { false } }
        let connected = rows.filter { $0.state == .connected }
        if !attention.isEmpty { result.append(ConnectListSection(kind: .needsAttention, rows: attention)) }
        if !connected.isEmpty { result.append(ConnectListSection(kind: .connected, rows: connected)) }
        let remaining = rows.filter { row in !attention.contains { $0.id == row.id } && !connected.contains { $0.id == row.id } }
        let extra = Set(remaining.map(\.category)).subtracting(categories).sorted()
        for category in categories + extra {
            let inCategory = remaining.filter { $0.category == category }
            if !inCategory.isEmpty { result.append(ConnectListSection(kind: .category(category), rows: inCategory)) }
        }
        return result
    }
}
