import Foundation
import PalConnect
import PalProtocol
import PalTransport

enum ConnectorDetailsScript {
    static let argument = "-hermes-test-connector-details"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func wrap(_ rpc: any ConnectRPC) -> any ConnectRPC {
        isActive ? ScriptedConnectorDetailsRPC(base: rpc) : rpc
    }
}

actor ScriptedConnectorDetailsRPC: ConnectRPC {
    private struct Account {
        var name: String
        var status: String
    }

    private struct Tool {
        let name: String
        let title: String
        let group: String

        init(_ title: String, _ group: String) {
            self.title = title
            self.group = group
            name = title.lowercased().replacingOccurrences(of: " ", with: "_")
        }
    }

    private struct Skill {
        let name: String
        let title: String
        let description: String
    }

    private struct Connector {
        let slug: String
        let name: String
        let category: String
        let method: String
        let description: String
        let host: String
        let grouped: Bool
        var accounts: [Account]
        var policy: [String: String]
        let tools: [Tool]
        let skills: [Skill]
        var connected: Bool { !accounts.isEmpty }
    }

    private let base: any ConnectRPC
    private var connectors: [Connector]

    init(base: any ConnectRPC) {
        self.base = base
        connectors = [Self.linear, Self.upwork, Self.github, Self.notion]
    }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "connectors.catalog": return catalog()
        case "connectors.details": return try details(params["slug"]?.stringValue ?? "")
        case "connectors.details.policy.set": return try setPolicy(params)
        case "mcp.servers.accounts.rename": return try rename(params)
        case "mcp.servers.remove" where connectors.contains { $0.slug == params["name"]?.stringValue }: return try remove(params)
        default: return try await base.call(method, params)
        }
    }

    private func catalog() -> JSONValue {
        .object(["connectors": .array(connectors.map(row))])
    }

    private func row(_ connector: Connector) -> JSONValue {
        let aggregate = connector.accounts.contains { $0.status == "connected" } ? "connected" : (connector.connected ? "needs_reconnect" : "not_connected")
        return [
            "slug": .string(connector.slug), "name": .string(connector.name), "category": .string(connector.category), "icon": "plugin_glyph",
            "method": .string(connector.method), "verified": true, "status": .string(aggregate), "multi_account": true,
            "mcp_url": .string("https://\(connector.host)/mcp"), "description": .string(connector.description),
            "source": .string("https://\(connector.host.replacingOccurrences(of: "mcp.", with: ""))/docs"),
            "accounts": .array(connector.accounts.map { ["name": .string($0.name), "status": .string($0.status)] }),
        ]
    }

    private func details(_ slug: String) throws -> JSONValue {
        guard let connector = connectors.first(where: { $0.slug == slug }) else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        guard connector.connected else { return ["slug": .string(slug), "grouped": false, "tools_known": false, "tools": [], "policy": [:], "skills": []] }
        return [
            "slug": .string(slug), "grouped": .bool(connector.grouped), "tools_known": true,
            "tools": .array(connector.tools.map { ["name": .string($0.name), "title": .string($0.title), "description": "", "group": .string($0.group)] }),
            "policy": .object(connector.policy.mapValues { .string($0) }),
            "skills": .array(connector.skills.map { ["name": .string($0.name), "title": .string($0.title), "description": .string($0.description)] }),
        ]
    }

    private func setPolicy(_ params: JSONValue) throws -> JSONValue {
        guard let index = connectors.firstIndex(where: { $0.slug == params["slug"]?.stringValue }),
            let group = params["group"]?.stringValue, let mode = params["mode"]?.stringValue
        else { throw Self.failure(4000, "INVALID_PARAMS") }
        connectors[index].policy[group] = mode
        return ["ok": true, "policy": .object(connectors[index].policy.mapValues { .string($0) })]
    }

    private func rename(_ params: JSONValue) throws -> JSONValue {
        guard let index = connectors.firstIndex(where: { $0.slug == params["name"]?.stringValue }),
            let old = params["account"]?.stringValue, let new = params["new_account"]?.stringValue,
            let position = connectors[index].accounts.firstIndex(where: { $0.name == old })
        else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        if connectors[index].accounts.contains(where: { $0.name == new }) { throw Self.failure(4090, "ALIAS_TAKEN") }
        connectors[index].accounts[position].name = new
        return ["ok": true]
    }

    private func remove(_ params: JSONValue) throws -> JSONValue {
        guard let index = connectors.firstIndex(where: { $0.slug == params["name"]?.stringValue }) else { throw Self.failure(4041, "CONNECTOR_NOT_FOUND") }
        if let account = params["account"]?.stringValue {
            connectors[index].accounts.removeAll { $0.name == account }
        } else {
            connectors[index].accounts = []
        }
        return ["ok": true]
    }

    private static func failure(_ code: Int, _ reason: String) -> GatewayTransportError {
        .rpc(RPCError(code: code, message: reason, data: ["reason": .string(reason)]))
    }

    private static let linear = Connector(
        slug: "linear", name: "Linear", category: "Work management", method: "mcp_oauth",
        description: "Search, create and update issues and projects in your Linear workspace.", host: "mcp.linear.app", grouped: false,
        accounts: [Account(name: "default", status: "connected")], policy: ["tool": "on"],
        tools: ["Create issue", "Update issue", "List issues", "Get issue", "Add comment", "List projects", "Get project", "Search documents"]
            .map { Tool($0, "tool") },
        skills: [
            Skill(name: "triage", title: "Triage new issues", description: "Sort new Linear issues by team and priority, and suggest an owner for each."),
            Skill(name: "weekly", title: "Weekly project update", description: "Summarise what shipped this week and what is blocked, ready to post."),
            Skill(name: "from-chat", title: "Issue from chat", description: "Turn a conversation into a Linear issue with a clear title and steps."),
        ]
    )

    private static let upwork = Connector(
        slug: "upwork", name: "Upwork", category: "Marketplace", method: "mcp_oauth",
        description: "Search Upwork jobs and freelancers, read proposals, contracts and messages, "
            + "and send proposals or messages only after you approve each one.",
        host: "mcp.upwork.com", grouped: true,
        accounts: [
            Account(name: "work", status: "connected"), Account(name: "personal", status: "needs_reconnect"),
            Account(name: "agency", status: "connected"),
        ],
        policy: ["read": "auto", "write": "ask"],
        tools: ["Search jobs", "Get job", "Search freelancers", "Get freelancer profile", "List proposals", "List contracts", "Read messages"]
            .map { Tool($0, "read") }
            + ["Send proposal", "Send message", "Edit profile", "Create job post", "Withdraw proposal", "Accept offer"].map { Tool($0, "write") }
            + ["Fund milestone", "Release payment", "Pay invoice"].map { Tool($0, "never") },
        skills: []
    )

    private static let github = Connector(
        slug: "github-mcp", name: "GitHub", category: "Developer tools", method: "mcp_oauth",
        description: "Read repositories, issues and pull requests, and open or comment on them when you ask.", host: "mcp.github.com", grouped: false,
        accounts: [Account(name: "work", status: "connected")], policy: ["tool": "on"],
        tools: ["Search code", "Get issue", "Create issue"].map { Tool($0, "tool") },
        skills: []
    )

    private static let notion = Connector(
        slug: "notion-mcp", name: "Notion", category: "Docs and files", method: "mcp_oauth",
        description: "Search and edit pages and databases in your Notion workspace.", host: "mcp.notion.com", grouped: false,
        accounts: [], policy: [:], tools: [], skills: []
    )
}
