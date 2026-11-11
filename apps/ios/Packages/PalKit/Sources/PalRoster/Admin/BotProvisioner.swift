import Foundation
import PalDiagnostics
import PalProtocol

public struct NewBotRequest: Sendable, Equatable {
    public var name: String
    public var kind: String
    public var colorHex: String
    public var seed: String?

    public init(name: String, kind: String, colorHex: String, seed: String? = nil) {
        self.name = name
        self.kind = kind
        self.colorHex = colorHex
        self.seed = seed
    }
}

public struct CreatedBot: Sendable, Equatable {
    public var name: String
    public var displayName: String
    public var greetsUnprompted: Bool

    public init(name: String, displayName: String, greetsUnprompted: Bool) {
        self.name = name
        self.displayName = displayName
        self.greetsUnprompted = greetsUnprompted
    }
}

public actor BotProvisioner {
    private struct Pending {
        var created: Bool
        var createdAtMilliseconds: Int
        var greetsUnprompted: Bool
    }

    private let gateway: RosterGateway
    private let writer: BotMetaWriter
    private let now: @Sendable () -> Date
    private let diagnostics: Diagnostics
    private var pending: [String: Pending] = [:]
    private var inFlight: [String: Task<CreatedBot, any Error>] = [:]

    public init(gateway: RosterGateway, now: @escaping @Sendable () -> Date = { Date() }, diagnostics: Diagnostics = .silent) {
        self.gateway = gateway
        writer = BotMetaWriter(gateway: gateway, diagnostics: diagnostics)
        self.now = now
        self.diagnostics = diagnostics
    }

    public func create(_ request: NewBotRequest) async throws -> CreatedBot {
        let identity = BotIdentity(entered: request.name)
        guard identity.isValid, Self.isColor(request.colorHex), Self.isKind(request.kind), Self.isSeed(request.seed) else {
            throw BotAdminError.invalidName
        }
        if let running = inFlight[identity.slug] { return try await running.value }
        let task = Task { try await self.provision(identity, request) }
        inFlight[identity.slug] = task
        defer { inFlight[identity.slug] = nil }
        do {
            return try await task.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BotAdminError.classify(error)
        }
    }

    private func provision(_ identity: BotIdentity, _ request: NewBotRequest) async throws -> CreatedBot {
        await discardAbandoned(except: identity.slug)
        let entry = try await ensureProfile(identity)
        let look = Self.look(identity, request, created: entry.createdAtMilliseconds)
        do {
            try await writer.update(identity.slug) { fields in
                fields.merging(look) { _, new in new }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "created bot \(identity.slug) but its look was not saved: \(Diagnostics.describe(error))")
            throw BotAdminError.incomplete(profile: identity.slug)
        }
        pending[identity.slug] = nil
        return CreatedBot(name: identity.slug, displayName: identity.displayName, greetsUnprompted: entry.greetsUnprompted)
    }

    private func ensureProfile(_ identity: BotIdentity) async throws -> Pending {
        let listing = try await writer.listing()
        let exists = listing.profiles.contains { $0.name == identity.slug }
        if var known = pending[identity.slug] {
            if known.created || exists {
                known.created = true
                pending[identity.slug] = known
                return known
            }
        } else if exists {
            throw BotAdminError.nameTaken
        }
        var entry = pending[identity.slug] ?? Pending(
            created: false,
            createdAtMilliseconds: Int(now().timeIntervalSince1970 * 1000),
            greetsUnprompted: listing.capabilities.botBirthNotice
        )
        pending[identity.slug] = entry
        _ = try await gateway.call("profiles.create", Self.createParams(identity))
        entry.created = true
        pending[identity.slug] = entry
        return entry
    }

    private func discardAbandoned(except slug: String) async {
        for (name, entry) in pending where name != slug {
            pending[name] = nil
            guard entry.created else { continue }
            do {
                _ = try await gateway.call("profiles.delete", ["name": .string(name)])
            } catch {
                diagnostics.warning("roster", "could not discard unfinished bot \(name): \(Diagnostics.describe(error))")
            }
        }
    }

    static func createParams(_ identity: BotIdentity) -> JSONValue {
        var params: [String: JSONValue] = [
            "name": .string(identity.slug),
            "clone_from": "default",
            "share_auth": true,
            "soul": .string(soul(for: identity)),
        ]
        if identity.displayName != identity.slug {
            params["display_name"] = .string(String(identity.displayName.prefix(BotIdentity.maximumDisplayNameLength)))
        }
        return .object(params)
    }

    static func soul(for identity: BotIdentity) -> String {
        [
            "# \(identity.displayName)",
            "",
            "You are \(identity.displayName), a persistent named agent (profile `\(identity.slug)`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions.",
        ].joined(separator: "\n")
    }

    static func look(_ identity: BotIdentity, _ request: NewBotRequest, created: Int) -> [String: JSONValue] {
        [
            "title": .string(identity.displayName),
            "color": .string(request.colorHex),
            "shape": .string("blobatar:\(request.seed ?? identity.slug):\(request.kind)"),
            "custom": true,
            "imageKind": "shape",
            "created": .int(created),
        ]
    }

    private static func isColor(_ value: String) -> Bool {
        value.count == 7 && value.hasPrefix("#") && value.dropFirst().allSatisfy(\.isHexDigit)
    }

    private static func isSeed(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.count <= BotIdentity.maximumSlugLength
            && value.unicodeScalars.allSatisfy { $0.isASCII && (Character($0).isLetter || Character($0).isNumber || $0 == "-" || $0 == "_") }
    }

    private static func isKind(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 24 && value.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
    }
}
