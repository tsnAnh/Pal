import Foundation
import PalProtocol

extension ConnectorToolGroup {
    public var title: String {
        switch self {
        case .read: String(localized: "Reads")
        case .write: String(localized: "Writes")
        case .never: String(localized: "Never allowed")
        case .tool: String(localized: "Tools")
        }
    }
}

extension ConnectorPolicyMode {
    public var title: String {
        switch self {
        case .auto: String(localized: "Runs without asking")
        case .ask: String(localized: "Ask first")
        case .off: String(localized: "Off")
        case .on: String(localized: "On")
        }
    }
}

public struct ConnectorToolSection: Identifiable, Sendable, Equatable {
    public var group: ConnectorToolGroup
    public var tools: [ConnectorDetailTool]
    public var mode: ConnectorPolicyMode?

    public var id: ConnectorToolGroup { group }
    public var title: String { group.title }
    public var count: Int { tools.count }
    public var options: [ConnectorPolicyMode] { group.modes }
    public var isFixed: Bool { group == .never }
}

public enum ConnectorDetailsLayout {
    public static let collapsedLimit = 5

    public static let writesFootnote = String(
        localized: "Writes always ask first. You can approve them automatically for one chat, from that chat. Steps that move money never run."
    )

    private static let groupedOrder: [ConnectorToolGroup] = [.read, .write, .never]

    public static func toolSections(_ details: ConnectorDetails) -> [ConnectorToolSection] {
        guard details.toolsKnown else { return [] }
        let order: [ConnectorToolGroup] = details.grouped ? groupedOrder : [.tool]
        return order.compactMap { group in
            let tools = details.tools.filter { $0.group == group }
            guard !tools.isEmpty else { return nil }
            return ConnectorToolSection(group: group, tools: tools, mode: details.policy.mode(for: group))
        }
    }

    public static func showsWritesFootnote(_ sections: [ConnectorToolSection]) -> Bool {
        sections.contains { $0.group == .write || $0.group == .never }
    }

    public static func visible(_ tools: [ConnectorDetailTool], showingAll: Bool) -> [ConnectorDetailTool] {
        showingAll ? tools : Array(tools.prefix(collapsedLimit))
    }

    public static func hasMore(_ tools: [ConnectorDetailTool]) -> Bool { tools.count > collapsedLimit }
}

public struct ConnectorInformationRow: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case signInMethod
        case category
        case verified
        case source
        case address
    }

    public var kind: Kind
    public var title: String
    public var value: String
    public var link: URL?

    public var id: Kind { kind }
}

public enum ConnectorInformation {
    public static func rows(for app: ConnectApp) -> [ConnectorInformationRow] {
        guard case .catalog(let entry) = app.source else { return [] }
        var rows: [ConnectorInformationRow] = []
        if let method = signInMethod(entry.method) {
            rows.append(ConnectorInformationRow(kind: .signInMethod, title: String(localized: "Sign-in method"), value: method))
        }
        if !entry.category.isEmpty {
            rows.append(ConnectorInformationRow(kind: .category, title: String(localized: "Category"), value: entry.category))
        }
        let verified = entry.verified ? String(localized: "Yes") : String(localized: "No")
        rows.append(ConnectorInformationRow(kind: .verified, title: String(localized: "Verified"), value: verified))
        if let source = entry.source {
            rows.append(ConnectorInformationRow(kind: .source, title: String(localized: "Source"), value: String(localized: "Setup guide"), link: source))
        }
        if let host = entry.mcpURL?.host, !host.isEmpty {
            rows.append(ConnectorInformationRow(kind: .address, title: String(localized: "Address"), value: host))
        }
        return rows
    }

    private static func signInMethod(_ method: PalCatalogEntry.Method) -> String? {
        switch method {
        case .mcpOAuth: String(localized: "Browser sign-in")
        case .apiKey: String(localized: "API key")
        case .oauthClient: String(localized: "Your own OAuth client")
        case .none: String(localized: "No sign-in needed")
        case .botApp, .botTokenStdio: String(localized: "Bot token")
        case .native, .unsupported: nil
        }
    }
}

extension ConnectApp {
    public var opensDetails: Bool {
        guard case .catalog(let entry) = source else { return false }
        switch entry.method {
        case .botApp, .botTokenStdio, .native, .unsupported: return false
        case .mcpOAuth, .none, .apiKey, .oauthClient: return true
        }
    }

    public var accountLine: String? {
        let names = accountNames
        guard !names.isEmpty, names.count > 1 || names[0] != ConnectorAccountName.defaultName else { return nil }
        return names.joined(separator: ", ")
    }
}
