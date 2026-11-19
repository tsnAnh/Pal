import Foundation
import PalDiagnostics
import PalProtocol

public struct LookPalette: Sendable, Equatable {
    public let kinds: [String]
    public let colors: [String]

    public init(kinds: [String], colors: [String]) {
        precondition(!kinds.isEmpty && !colors.isEmpty, "a look palette needs at least one shape and one colour")
        self.kinds = kinds
        self.colors = colors
    }
}

public enum LooklessFill {
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func look(for name: String, palette: LookPalette) -> [String: JSONValue] {
        let hash = fnv1a(name)
        let kind = palette.kinds[Int(hash % UInt64(palette.kinds.count))]
        let color = palette.colors[Int((hash >> 32) % UInt64(palette.colors.count))]
        return [
            "color": .string(color),
            "shape": .string("blobatar:\(name):\(kind)"),
            "custom": true,
            "imageKind": "shape",
        ]
    }

    public static func isEligible(_ profile: RosterProfile) -> Bool {
        !profile.isPrimary && !profile.isDefault && profile.name.lowercased() != "default"
            && !profile.hasAvatar && isLookless(profile.botMeta)
    }

    public static func isLookless(_ meta: BotMeta) -> Bool {
        meta.shape == nil && meta.color == nil
            && meta.fields["imageKind"]?.stringValue != "photo"
            && (meta.fields["image"]?.stringValue ?? "").isEmpty
    }

    public static func filled(
        _ fields: [String: JSONValue],
        name: String,
        displayName: String,
        palette: LookPalette
    ) -> [String: JSONValue] {
        let meta = BotMeta(fields: fields)
        guard isLookless(meta) else { return fields }
        var next = fields.merging(look(for: name, palette: palette)) { _, new in new }
        if meta.title == nil { next["title"] = .string(displayName) }
        return next
    }

    public static func effectiveUIMeta(for profile: RosterProfile, palette: LookPalette) -> JSONValue? {
        guard isEligible(profile) else { return profile.uiMeta }
        var root = profile.uiMeta?.objectValue ?? [:]
        root[BotMeta.namespace] = .object(
            filled(profile.botMeta.fields, name: profile.name, displayName: profile.resolvedDisplayName, palette: palette)
        )
        return .object(root)
    }
}

public struct LooklessFiller: Sendable {
    private let writer: BotMetaWriter
    private let palette: LookPalette
    private let diagnostics: Diagnostics

    public init(gateway: RosterGateway, palette: LookPalette, diagnostics: Diagnostics = .silent) {
        writer = BotMetaWriter(gateway: gateway, diagnostics: diagnostics)
        self.palette = palette
        self.diagnostics = diagnostics
    }

    public func fill(_ profiles: [RosterProfile]) async {
        for profile in profiles where LooklessFill.isEligible(profile) {
            if Task.isCancelled { return }
            let palette = palette
            let name = profile.name
            let displayName = profile.resolvedDisplayName
            do {
                try await writer.update(name) {
                    LooklessFill.filled($0, name: name, displayName: displayName, palette: palette)
                }
            } catch is CancellationError {
                return
            } catch {
                diagnostics.warning("roster", "could not save a look for bot \(name): \(Diagnostics.describe(error))")
            }
        }
    }
}
