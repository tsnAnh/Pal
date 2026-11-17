import Foundation
import PalProtocol

public struct SetupCheckFailure: Sendable, Equatable {
    public var code: String
    public var reason: String
}

public struct SetupCheckResult: Sendable, Equatable {
    public var slug: String
    public var ok: Bool
    public var reason: String?
    public var message: String?
    public var account: String?

    public init(slug: String, ok: Bool, reason: String? = nil, message: String? = nil, account: String? = nil) {
        self.slug = slug
        self.ok = ok
        self.reason = reason
        self.message = message
        self.account = account
    }

    init(_ value: JSONValue, slug: String) throws {
        guard let ok = value["ok"]?.boolValue else { throw ConnectAppsError.failed }
        self.init(
            slug: value["slug"]?.stringValue ?? slug, ok: ok, reason: Self.text(value["reason"]),
            message: Self.text(value["message"]), account: Self.text(value["account"])
        )
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public func failure(appName: String) -> SetupCheckFailure {
        let code = reason?.uppercased() ?? "CHECK_FAILED"
        let text: String = switch code {
        case "INVALID_TOKEN": String(localized: "\(appName) didn't accept that token. Check it and paste it again.")
        case "INVALID_CLIENT": String(localized: "\(appName) didn't accept that client ID and secret. Check both and paste them again.")
        case "CHECK_UNAVAILABLE": String(localized: "Pal couldn't reach \(appName) to check. Try again in a moment.")
        default: message ?? String(localized: "Pal couldn't check that. Try again.")
        }
        return SetupCheckFailure(code: code, reason: text)
    }
}

public struct SetupVerification: Sendable {
    public let result: SetupCheckResult
    let items: [String: String]
}

extension ConnectAppsService {
    public func catalogEntry(slug: String) async throws -> PalCatalogEntry? {
        try decodeList(await call("connectors.catalog"), key: "connectors", as: PalCatalogEntry.self).first { $0.slug == slug }
    }

    public func verifySetup(_ entry: PalCatalogEntry, step: SetupStep, values: [String: String]) async throws -> SetupVerification {
        var items: [String: String] = [:]
        do {
            for field in step.fields {
                guard let value = values[field.id], !value.isEmpty else { throw ConnectAppsError.oauthClient(.saveFailed) }
                items[field.id] = try await storeVaultSecret(label: "\(entry.name) \(field.label)", value: value)
            }
            guard step.check != nil else { return SetupVerification(result: SetupCheckResult(slug: entry.slug, ok: true), items: items) }
            let sent = items.mapValues { JSONValue.string($0) }
            let reply = try await oauthClientCall("connectors.setup.check", ["slug": .string(entry.slug), "values": .object(sent)])
            let result = try SetupCheckResult(reply, slug: entry.slug)
            if !result.ok { await discardVaultItems(Array(items.values)) }
            return SetupVerification(result: result, items: result.ok ? items : [:])
        } catch {
            await discardVaultItems(Array(items.values))
            throw error
        }
    }

    public func saveVerifiedClient(_ entry: PalCatalogEntry, _ verification: SetupVerification) async throws {
        guard let idItem = verification.items["client_id"], let secretItem = verification.items["client_secret"] else {
            await discardVaultItems(Array(verification.items.values))
            throw ConnectAppsError.oauthClient(.saveFailed)
        }
        _ = try await saveOAuthClientItems(entry, idItem: idItem, secretItem: secretItem)
    }

    public func discardVerified(_ verification: SetupVerification) async {
        await discardVaultItems(Array(verification.items.values))
    }
}
