import Foundation
import Observation
import PalProtocol
import PalRoster
import PalTransport

public struct TemplateReview: Sendable, Equatable {
    public let digest: String
    public let size: Int
    public let displayName: String
    public let summary: String
    public let suggestedName: String
    public let suggestedDisplayName: String
    public let model: String?
    public let skills: [String]
    public let connections: [String]
    public let routines: [String]
    public let skippedRoutines: Int
    public let toolsets: [String]?
    public let hasPersona: Bool
    public let hasAvatar: Bool
}

public struct ImportedBot: Sendable, Equatable {
    public let name: String
    public let displayName: String
}

public enum TemplateImportError: Error, Sendable, Equatable {
    case invalidFile
    case changedAfterReview
    case nameUnavailable
    case unsupportedVersion
    case tooLarge
    case unreadable
    case permissionDenied
    case unavailable

    public var message: String {
        switch self {
        case .invalidFile: "This file isn't a bot template Pal can use."
        case .changedAfterReview: "This template changed after you reviewed it. Choose it again to review it."
        case .nameUnavailable: "A bot with that name already exists. Pick another name."
        case .unsupportedVersion: "This template was made by a newer version of Pal. Update Pal and try again."
        case .tooLarge: "This template is too large to import."
        case .unreadable: "Couldn't read that file."
        case .permissionDenied: "This device isn't allowed to create bots."
        case .unavailable: "Couldn't import this template. Try again."
        }
    }

    var keepsReview: Bool {
        switch self {
        case .nameUnavailable, .permissionDenied, .unavailable: true
        default: false
        }
    }

    static func classify(_ error: any Error) -> TemplateImportError {
        if let known = error as? TemplateImportError { return known }
        guard case GatewayTransportError.rpc(let rpc) = error else { return .unavailable }
        switch rpc.code {
        case 4071: return .invalidFile
        case 4072: return .changedAfterReview
        case 4073: return .nameUnavailable
        case 4074: return .unsupportedVersion
        case 4075: return .tooLarge
        case 4076: return .unreadable
        default:
            return BotsError.classify(error) == .permissionDenied ? .permissionDenied : .unavailable
        }
    }

    static func surface(_ error: any Error) -> any Error {
        error is CancellationError ? error : classify(error)
    }
}

struct LossyList<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    init(from decoder: any Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !list.isAtEnd {
            if let element = try? list.decode(Element.self) {
                decoded.append(element)
            } else {
                _ = try? list.decode(Skipped.self)
            }
        }
        elements = decoded
    }
}

struct TemplateImportWire: Decodable {
    struct Named: Decodable {
        let name: String
    }

    struct Pin: Decodable {
        let provider: String?
        let `default`: String?
    }

    struct Review: Decodable {
        let digest: String
        let size: Int?
        let displayName: String?
        let description: String?
        let suggestedName: String?
        let suggestedDisplayName: String?
        let soul: String?
        let model: Pin?
        let toolsets: [String]?
        let skills: LossyList<Named>?
        let mcpServers: LossyList<Named>?
        let routines: LossyList<Named>?
        let skippedRoutines: LossyList<String>?
        let hasAvatar: Bool?

        enum CodingKeys: String, CodingKey {
            case digest, size, description, soul, model, toolsets, skills, routines
            case displayName = "display_name"
            case suggestedName = "suggested_name"
            case suggestedDisplayName = "suggested_display_name"
            case mcpServers = "mcp_servers"
            case skippedRoutines = "skipped_routines"
            case hasAvatar = "has_avatar"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            digest = try c.decode(String.self, forKey: .digest)
            size = try? c.decodeIfPresent(Int.self, forKey: .size)
            displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            suggestedName = try? c.decodeIfPresent(String.self, forKey: .suggestedName)
            suggestedDisplayName = try? c.decodeIfPresent(String.self, forKey: .suggestedDisplayName)
            soul = try? c.decodeIfPresent(String.self, forKey: .soul)
            model = try? c.decodeIfPresent(Pin.self, forKey: .model)
            toolsets = try? c.decodeIfPresent([String].self, forKey: .toolsets)
            skills = try? c.decodeIfPresent(LossyList<Named>.self, forKey: .skills)
            mcpServers = try? c.decodeIfPresent(LossyList<Named>.self, forKey: .mcpServers)
            routines = try? c.decodeIfPresent(LossyList<Named>.self, forKey: .routines)
            skippedRoutines = try? c.decodeIfPresent(LossyList<String>.self, forKey: .skippedRoutines)
            hasAvatar = try? c.decodeIfPresent(Bool.self, forKey: .hasAvatar)
        }

        func review() -> TemplateReview? {
            let reviewedDigest = digest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reviewedDigest.isEmpty else { return nil }
            let suggestedDisplay = ReasoningEffort.clean(suggestedDisplayName) ?? ReasoningEffort.clean(displayName) ?? ""
            let pinned = model.flatMap { entry -> String? in
                ReasoningEffort.clean(entry.default).map { name in
                    ReasoningEffort.clean(entry.provider).map { "\($0)/\(name)" } ?? name
                }
            }
            return TemplateReview(
                digest: reviewedDigest,
                size: max(size ?? 0, 0),
                displayName: ReasoningEffort.clean(displayName) ?? suggestedDisplay,
                summary: ReasoningEffort.clean(description) ?? "",
                suggestedName: ReasoningEffort.clean(suggestedName) ?? "",
                suggestedDisplayName: suggestedDisplay,
                model: pinned,
                skills: skills?.elements.map(\.name) ?? [],
                connections: mcpServers?.elements.map(\.name) ?? [],
                routines: routines?.elements.map(\.name) ?? [],
                skippedRoutines: skippedRoutines?.elements.count ?? 0,
                toolsets: toolsets,
                hasPersona: ReasoningEffort.clean(soul) != nil,
                hasAvatar: hasAvatar ?? false)
        }
    }

    struct Created: Decodable {
        let name: String
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case displayName = "display_name"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        }
    }

    let dryRun: Bool?
    let review: Review?
    let created: Created?

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case review
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dryRun = try? c.decodeIfPresent(Bool.self, forKey: .dryRun)
        review = try? c.decodeIfPresent(Review.self, forKey: .review)
        created = try? Created(from: decoder)
    }
}

public struct TemplateImportClient: Sendable {
    public static let maximumBytes = 50 * 1024 * 1024

    let gateway: BotsGateway

    public init(gateway: BotsGateway) {
        self.gateway = gateway
    }

    public func review(_ data: Data) async throws -> TemplateReview {
        guard !data.isEmpty else { throw TemplateImportError.unreadable }
        guard data.count <= Self.maximumBytes else { throw TemplateImportError.tooLarge }
        do {
            let result = try await gateway.call("profiles.template.import", [
                "data": .string(data.base64EncodedString()),
                "dry_run": true,
            ])
            let wire = try gateway.decoded(TemplateImportWire.self, result)
            guard wire.dryRun == true, let review = wire.review?.review() else { throw BotsError.invalidResponse }
            return review
        } catch {
            throw TemplateImportError.surface(error)
        }
    }

    public func commit(_ data: Data, review: TemplateReview, name: String? = nil, displayName: String? = nil) async throws -> ImportedBot {
        var params: [String: JSONValue] = [
            "data": .string(data.base64EncodedString()),
            "reviewed_digest": .string(review.digest),
        ]
        if let name { params["name"] = .string(name) }
        if let displayName { params["display_name"] = .string(displayName) }
        do {
            let result = try await gateway.call("profiles.template.import", params)
            let wire = try gateway.decoded(TemplateImportWire.self, result)
            guard wire.dryRun != true, let created = wire.created, !created.name.isEmpty else { throw BotsError.invalidResponse }
            return ImportedBot(name: created.name, displayName: ReasoningEffort.clean(created.displayName) ?? created.name)
        } catch {
            throw TemplateImportError.surface(error)
        }
    }
}

@MainActor
@Observable
public final class TemplateImportModel {
    public enum Phase: Sendable, Equatable {
        case idle
        case reading
        case reviewing
        case importing
        case imported(ImportedBot)
    }

    public private(set) var phase = Phase.idle
    public private(set) var review: TemplateReview?
    public private(set) var failure: TemplateImportError?
    public var name = "" {
        didSet { if name != oldValue, failure == .nameUnavailable { failure = nil } }
    }

    @ObservationIgnored private let client: TemplateImportClient
    @ObservationIgnored private var data: Data?

    public init(client: TemplateImportClient) {
        self.client = client
    }

    public var isBusy: Bool { phase == .reading || phase == .importing }

    public var identity: BotIdentity { BotIdentity(entered: name) }

    public var canImport: Bool { phase == .reviewing && identity.isValid }

    public func fail(_ error: TemplateImportError) {
        guard !isBusy else { return }
        failure = error
    }

    public func begin(_ file: Data) async {
        guard !isBusy else { return }
        phase = .reading
        failure = nil
        do {
            let reviewed = try await client.review(file)
            data = file
            review = reviewed
            name = reviewed.suggestedDisplayName
            phase = .reviewing
        } catch {
            discard()
            failure = TemplateImportError.classify(error)
        }
    }

    public func confirm() async -> ImportedBot? {
        guard canImport, let review, let data else { return nil }
        phase = .importing
        failure = nil
        let edited = identity.displayName != review.suggestedDisplayName
        do {
            let created = try await client.commit(
                data, review: review,
                name: edited ? identity.slug : nil,
                displayName: edited ? identity.displayName : nil)
            discard()
            phase = .imported(created)
            return created
        } catch {
            let reason = TemplateImportError.classify(error)
            if reason.keepsReview {
                phase = .reviewing
            } else {
                discard()
            }
            failure = reason
            return nil
        }
    }

    public func reset() {
        guard !isBusy else { return }
        discard()
        failure = nil
    }

    private func discard() {
        data = nil
        review = nil
        name = ""
        phase = .idle
    }
}
