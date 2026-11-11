import Foundation
import HermesDiagnostics
import HermesProtocol
import HermesTransport

public enum SkillsCatalogError: Error, Sendable, Equatable {
    case signInRequired
    case installBlocked
    case installFailed
    case updateFailed
    case uninstallFailed
    case notFound
    case invalidRequest
    case invalidKey
    case keyNotSaved
    case unavailable

    public var userMessage: String {
        switch self {
        case .signInRequired: String(localized: "Sign in to Nous Portal on your Hermes first, then try again.")
        case .installBlocked: String(localized: "This skill was blocked by a safety check and wasn't installed.")
        case .installFailed: String(localized: "Couldn't install this skill. Try again.")
        case .updateFailed: String(localized: "Couldn't update. Try again.")
        case .uninstallFailed: String(localized: "Couldn't remove this skill. Try again.")
        case .notFound: String(localized: "This skill couldn't be found.")
        case .invalidRequest: String(localized: "That skill can't be changed from here.")
        case .invalidKey: String(localized: "That key wasn't accepted. Check it and try again.")
        case .keyNotSaved: String(localized: "Couldn't save the key. Try again.")
        case .unavailable: String(localized: "Couldn't reach your bot. Check your connection and try again.")
        }
    }

    static func map(_ error: any Error) -> SkillsCatalogError {
        guard let transport = error as? GatewayTransportError, case .rpc(let rpc) = transport else { return .unavailable }
        switch rpc.code {
        case 5031: return Self.blocks(rpc) ? .installBlocked : .installFailed
        case 5032: return .updateFailed
        case 5033: return .uninstallFailed
        case 4003: return .invalidRequest
        case 4101: return .invalidKey
        case 4004: return .notFound
        case 5034: return .keyNotSaved
        default: return ConnectAppsService.map(.rpc(rpc)) == .signInRequired ? .signInRequired : .unavailable
        }
    }

    private static func blocks(_ rpc: RPCError) -> Bool {
        let log = (rpc.data?["log"]?.stringValue ?? "").lowercased()
        return ["blocked", "scan", "dangerous"].contains { log.contains($0) }
    }
}

public struct SkillsPage: Sendable, Equatable {
    public var items: [SkillHubItem]
    public var page: Int
    public var totalPages: Int

    public init(items: [SkillHubItem], page: Int, totalPages: Int) {
        self.items = items
        self.page = page
        self.totalPages = totalPages
    }

    public var hasMore: Bool { page < totalPages }
}

public struct SkillsCatalogService: Sendable {
    public static let pageSize = 20

    private let rpc: any ConnectRPC
    private let profile: String?
    private let diagnostics: Diagnostics

    public init(rpc: any ConnectRPC, profile: String?, diagnostics: Diagnostics = .silent) {
        self.rpc = rpc
        self.profile = profile
        self.diagnostics = diagnostics
    }

    private func scoped(_ params: [String: JSONValue]) -> JSONValue {
        var params = params
        if let profile { params["profile"] = .string(profile) }
        return .object(params)
    }

    private func manage(
        _ action: String, query: String? = nil, page: Int? = nil, extra: [String: JSONValue] = [:]
    ) async throws -> JSONValue {
        var params = extra
        params["action"] = .string(action)
        if let query { params["query"] = .string(query) }
        if let page { params["page"] = .int(page) }
        if page != nil { params["page_size"] = .int(Self.pageSize) }
        do {
            return try await rpc.call("skills.manage", scoped(params))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.info("skills", "\(action) failed: \(Diagnostics.describe(error))")
            throw SkillsCatalogError.map(error)
        }
    }

    public func browse(page: Int = 1) async throws -> SkillsPage {
        let reply = try await manage("browse", page: max(page, 1))
        return SkillsPage(
            items: SkillHubItem.parse(reply, key: "items"), page: reply["page"]?.intValue ?? page,
            totalPages: reply["total_pages"]?.intValue ?? 1
        )
    }

    public func search(_ query: String) async throws -> [SkillHubItem] {
        guard let needle = query.nonBlank else { return [] }
        return SkillHubItem.parse(try await manage("search", query: needle), key: "results")
    }

    public func inspect(_ target: String) async throws -> SkillDetail {
        guard let target = target.nonBlank else { throw SkillsCatalogError.invalidRequest }
        guard let detail = SkillDetail.parse(try await manage("inspect", query: target)) else { throw SkillsCatalogError.notFound }
        return detail
    }

    public func installState() async throws -> SkillsInstallState {
        async let hub = manage("installed")
        async let local = bestEffort { InstalledSkill.parse(try await manage("list")) }
        async let updates = bestEffort { SkillUpdateStatus.parse(try await manage("check")) }
        let installed = HubInstalledSkill.parse(try await hub)
        return SkillsInstallState(hubInstalled: installed, bundled: await local ?? [], updates: await updates ?? [])
    }

    private func bestEffort<T: Sendable>(_ work: () async throws -> T) async -> T? {
        try? await work()
    }

    public func install(_ target: String) async throws {
        guard let target = target.nonBlank else { throw SkillsCatalogError.invalidRequest }
        _ = try await manage("install", query: target)
        await reloadAgent()
    }

    public func update(name: String?) async throws {
        let target = name?.nonBlank
        if name != nil, target == nil { throw SkillsCatalogError.invalidRequest }
        _ = try await manage("update", query: target)
        await reloadAgent()
    }

    public func uninstall(name: String) async throws {
        guard let name = name.nonBlank else { throw SkillsCatalogError.invalidRequest }
        _ = try await manage("uninstall", query: name)
        await reloadAgent()
    }

    public func setKey(skill: String, keyName: String, value: SecretString) async throws {
        guard let skill = skill.nonBlank, let keyName = keyName.nonBlank else { throw SkillsCatalogError.invalidRequest }
        guard !value.isEmpty else { throw SkillsCatalogError.invalidKey }
        _ = try await manage("set_key", query: skill, extra: ["key_name": .string(keyName), "value": .string(value.reveal())])
    }

    private func reloadAgent() async {
        do { _ = try await rpc.call("skills.reload", scoped([:])) } catch {
            diagnostics.info("skills", "reload failed: \(Diagnostics.describe(error))")
        }
    }
}
