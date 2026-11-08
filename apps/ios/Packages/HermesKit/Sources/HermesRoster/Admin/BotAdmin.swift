import Foundation
import HermesDiagnostics
import HermesProtocol

public struct BotAdmin: Sendable {
    private let gateway: RosterGateway
    private let writer: BotMetaWriter
    private let diagnostics: Diagnostics

    public init(gateway: RosterGateway, diagnostics: Diagnostics = .silent) {
        self.gateway = gateway
        self.diagnostics = diagnostics
        writer = BotMetaWriter(gateway: gateway, diagnostics: diagnostics)
    }

    @discardableResult
    public func setPinned(_ profile: String, pinned: Bool) async throws -> BotMeta {
        do {
            return try await writer.update(profile) { fields in
                var next = fields
                next[BotMeta.pinnedKey] = .bool(pinned)
                return next
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "pin change failed: \(Diagnostics.describe(error))")
            throw BotAdminError.classify(error)
        }
    }

    public func makePrimary(_ profile: String) async throws {
        do {
            let result = try await gateway.call("profiles.set_primary", ["name": .string(profile)])
            guard result["ok"]?.boolValue == true else { throw BotAdminError.rejected }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            diagnostics.warning("roster", "make primary failed: \(Diagnostics.describe(error))")
            throw BotAdminError.classify(error)
        }
    }
}
