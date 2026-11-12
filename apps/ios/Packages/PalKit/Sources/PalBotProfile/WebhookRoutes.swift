import Foundation
import Observation
import PalProtocol
import PalTransport

public struct WebhookRoute: Sendable, Equatable, Identifiable {
    public let name: String
    public let profile: String?
    public let path: String
    public let publicURL: URL?
    public let events: [String]
    public let deliver: String?
    public let description: String?
    public let createdAt: String?
    public let isEnabled: Bool

    public var id: String { name }

    init?(_ value: JSONValue) {
        guard let name = Self.text(value["name"]?.stringValue) else { return nil }
        self.name = name
        profile = Self.text(value["profile"]?.stringValue)
        path = value["path"]?.stringValue ?? ""
        publicURL = Self.text(value["public_url"]?.stringValue).flatMap(Self.webURL)
        events = (value["events"]?.arrayValue ?? []).compactMap { Self.text($0.stringValue) }
        deliver = Self.text(value["deliver"]?.stringValue)
        description = Self.text(value["description"]?.stringValue)
        createdAt = Self.text(value["created_at"]?.stringValue)
        isEnabled = value["enabled"]?.boolValue ?? true
    }

    static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host()?.isEmpty == false
        else { return nil }
        return url
    }
}

public struct WebhookRouteList: Sendable, Equatable {
    public let isEnabled: Bool
    public let publicBaseURL: String?
    public let publicURLSetting: String?
    public let routes: [WebhookRoute]

    init(_ value: JSONValue) {
        isEnabled = value["enabled"]?.boolValue ?? false
        publicBaseURL = WebhookRoute.text(value["public_base_url"]?.stringValue)
        publicURLSetting = WebhookRoute.text(value["public_url_setting"]?.stringValue)
        routes = (value["routes"]?.arrayValue ?? []).compactMap(WebhookRoute.init)
    }

    public var publicAddressText: String {
        if let publicBaseURL { return publicBaseURL }
        return "Not configured"
    }

    public var missingSettingHint: String? {
        guard publicBaseURL == nil else { return nil }
        guard let publicURLSetting else { return "Set the public address on the computer that runs Pal." }
        return "Set \(publicURLSetting) on the computer that runs Pal."
    }
}

public struct WebhookHop: Sendable, Equatable {
    public let status: Int?
    public let milliseconds: Int?
    public let error: String?

    init(_ value: JSONValue?) {
        status = value?["status"]?.intValue
        milliseconds = value?["ms"]?.intValue
        error = WebhookRoute.text(value?["error"]?.stringValue)
    }

    public var summary: String {
        if let status {
            let timing = milliseconds.map { " in \($0) ms" } ?? ""
            return "Answered \(status)\(timing)"
        }
        if let error { return "No answer: \(error)" }
        return "Not checked"
    }
}

public enum WebhookSeverity: Sendable, Equatable {
    case good
    case warning
    case failure
    case neutral
}

public struct WebhookDiagnosis: Sendable, Equatable {
    public let code: String
    public let message: String

    init(_ value: JSONValue?) {
        code = value?["code"]?.stringValue ?? ""
        message = WebhookRoute.text(value?["message"]?.stringValue) ?? ""
    }

    public var headline: String { Self.entry(code)?.headline ?? "Check finished" }

    public var severity: WebhookSeverity { Self.entry(code)?.severity ?? .neutral }

    public var isKnown: Bool { Self.entry(code) != nil }

    private struct Entry {
        let headline: String
        let severity: WebhookSeverity
    }

    private static func entry(_ code: String) -> Entry? { table[code] }

    private static let table: [String: Entry] = [
        "ok": Entry(headline: "Working", severity: .good),
        "route_not_loaded": Entry(headline: "Pal hasn't loaded this address", severity: .failure),
        "route_disabled": Entry(headline: "This address is turned off", severity: .warning),
        "local_unreachable": Entry(headline: "Pal isn't answering on its own computer", severity: .failure),
        "public_unconfigured": Entry(headline: "No public address set", severity: .warning),
        "public_not_reaching_gateway": Entry(headline: "The public address isn't reaching Pal", severity: .failure),
        "public_wrong_target": Entry(headline: "The public address points somewhere else", severity: .failure),
        "public_timeout": Entry(headline: "The public address timed out", severity: .failure),
        "public_tls": Entry(headline: "Certificate problem on the public address", severity: .failure),
        "public_dns": Entry(headline: "The public address doesn't resolve", severity: .failure),
        "public_unreachable": Entry(headline: "The public address can't be reached", severity: .failure),
        "probe_skipped": Entry(headline: "Check skipped", severity: .neutral),
    ]
}

public struct WebhookProbe: Sendable, Equatable {
    public let local: WebhookHop
    public let publicHop: WebhookHop
    public let diagnosis: WebhookDiagnosis
    public let resolves: Bool?
    public let certificateExpiresAt: String?

    init(_ value: JSONValue) {
        local = WebhookHop(value["local"])
        publicHop = WebhookHop(value["public"])
        diagnosis = WebhookDiagnosis(value["diagnosis"])
        resolves = value["tunnel"]?["resolves"]?.boolValue
        certificateExpiresAt = WebhookRoute.text(value["tunnel"]?["tls_expires_at"]?.stringValue)
    }
}

public struct WebhookRouteDraft: Sendable, Equatable {
    public var name = ""
    public var eventsText = ""

    public init(name: String = "", eventsText: String = "") {
        self.name = name
        self.eventsText = eventsText
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var events: [String] {
        eventsText
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var isComplete: Bool { !trimmedName.isEmpty && !trimmedName.contains(where: \.isWhitespace) }
}

public enum WebhookRoutesFailure: Error, Sendable, Equatable {
    case unsupported
    case notOwner
    case unavailable

    static func classify(_ error: any Error) -> WebhookRoutesFailure {
        if let failure = error as? WebhookRoutesFailure { return failure }
        if case GatewayTransportError.rpc(let rpc) = error {
            if rpc.code == -32601 { return .unsupported }
            if rpc.code == 4403 { return .notOwner }
        }
        return .unavailable
    }
}

public struct WebhookRoutesClient: Sendable {
    private let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func list() async throws -> WebhookRouteList {
        let result = try await perform("webhook.routes.list")
        guard result.objectValue != nil else { throw WebhookRoutesFailure.unavailable }
        return WebhookRouteList(result)
    }

    public func add(_ draft: WebhookRouteDraft, secret: String?) async throws -> String? {
        var params: [String: JSONValue] = ["name": .string(draft.trimmedName)]
        if !draft.events.isEmpty { params["events"] = .array(draft.events.map { .string($0) }) }
        if let secret { params["secret"] = .string(secret) } else { params["generate_secret"] = .bool(true) }
        let result = try await perform("webhook.routes.add", params)
        guard result["route"]?.objectValue != nil else { throw WebhookRoutesFailure.unavailable }
        return secret == nil ? WebhookRoute.text(result["secret"]?.stringValue) : nil
    }

    public func remove(_ name: String) async throws {
        let result = try await perform("webhook.routes.remove", ["name": .string(name)])
        guard result["ok"]?.boolValue != false else { throw WebhookRoutesFailure.unavailable }
    }

    public func probe(_ name: String) async throws -> WebhookProbe {
        let result = try await perform("webhook.routes.probe", ["name": .string(name)])
        guard result.objectValue != nil else { throw WebhookRoutesFailure.unavailable }
        return WebhookProbe(result)
    }

    private func perform(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        do {
            return try await gateway.call(method, params)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebhookRoutesFailure.classify(error)
        }
    }
}

@MainActor
@Observable
public final class WebhookRoutesModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case unsupported
        case notOwner
        case unavailable
        case ready(WebhookRouteList)
    }

    public enum ProbeState: Sendable, Equatable {
        case running
        case finished(WebhookProbe)
        case failed
    }

    public enum AddState: Sendable, Equatable {
        case idle
        case saving
        case failed(String)
    }

    static let addFailure = "We couldn't add that address. Check the name and try again."
    static let removeFailure = "We couldn't remove that address. Please try again."

    public private(set) var phase: Phase = .loading
    public private(set) var probes: [String: ProbeState] = [:]
    public private(set) var addState: AddState = .idle
    public private(set) var issuedSecret: String?
    public private(set) var issuedRouteName: String?
    public var notice: String?
    @ObservationIgnored private let client: WebhookRoutesClient
    @ObservationIgnored private var isRefreshing = false

    public init(client: WebhookRoutesClient) {
        self.client = client
    }

    public var list: WebhookRouteList? {
        if case .ready(let list) = phase { list } else { nil }
    }

    public var routes: [WebhookRoute] { list?.routes ?? [] }

    public var footnote: String? {
        switch phase {
        case .unsupported: "This computer's Pal is too old for public access. Update it, then refresh."
        case .notOwner: "Only the owner of this computer can manage public access."
        case .unavailable: "Couldn't check public access. Refresh to try again."
        case .loading, .ready: nil
        }
    }

    public var canManage: Bool {
        if case .ready = phase { true } else { false }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            phase = .ready(try await client.list())
        } catch is CancellationError {
        } catch {
            apply(WebhookRoutesFailure.classify(error), keepingReady: true)
        }
    }

    public func probe(_ name: String) async {
        guard probes[name] != .running else { return }
        probes[name] = .running
        do {
            probes[name] = .finished(try await client.probe(name))
        } catch is CancellationError {
            probes[name] = nil
        } catch {
            probes[name] = .failed
            apply(WebhookRoutesFailure.classify(error), keepingReady: true)
        }
    }

    @discardableResult
    public func add(_ draft: WebhookRouteDraft, typedSecret: String?) async -> Bool {
        guard draft.isComplete, addState != .saving else {
            addState = .failed(Self.addFailure)
            return false
        }
        let typed = typedSecret.flatMap { WebhookRoute.text($0) }
        if typedSecret != nil, typed == nil {
            addState = .failed(Self.addFailure)
            return false
        }
        addState = .saving
        do {
            let generated = try await client.add(draft, secret: typed)
            issuedSecret = generated
            issuedRouteName = generated == nil ? nil : draft.trimmedName
            addState = .idle
            await refresh()
            return true
        } catch is CancellationError {
            addState = .idle
            return false
        } catch {
            addState = .failed(Self.addFailure)
            apply(WebhookRoutesFailure.classify(error), keepingReady: true)
            return false
        }
    }

    public func remove(_ name: String) async {
        do {
            try await client.remove(name)
            probes[name] = nil
            await refresh()
        } catch is CancellationError {
        } catch {
            notice = Self.removeFailure
        }
    }

    public func resetAdd() {
        addState = .idle
    }

    public func clearIssuedSecret() {
        issuedSecret = nil
        issuedRouteName = nil
    }

    private func apply(_ failure: WebhookRoutesFailure, keepingReady: Bool = false) {
        if keepingReady, canManage, failure == .unavailable { return }
        switch failure {
        case .unsupported: phase = .unsupported
        case .notOwner: phase = .notOwner
        case .unavailable: phase = .unavailable
        }
    }
}
