import Foundation
import PalProtocol
@testable import PalRoster
import Testing

@Suite("Lookless effective ui meta")
struct LooklessEffectiveMetaTests {
    private static let palette = LookPalette(
        kinds: ["round", "cloud", "boxy", "spark", "clover", "nub", "sun", "droplet", "capsule", "triangle", "gem", "burst", "hexagon"],
        colors: ["#ffffff", "#845634", "#ed0a37", "#f15105", "#f58a06", "#10dc69", "#0ec79b", "#1b7af8", "#833cf8", "#ee0d8f", "#6c6c6c"]
    )
    private static let lookKeys: Set<String> = ["shape", "color", "custom", "imageKind"]
    private static let foreignNamespace: JSONValue = .object(["theme": "dark", "order": .array([1, 2, 3])])
    private static let unrelatedFields: [String: JSONValue] = [
        "pinned": true,
        "hidden": false,
        "future-flag": .array(["a", .object(["nested": 1])]),
        "note": "keep me",
    ]

    private func profile(
        _ name: String,
        displayName: String? = nil,
        bot: [String: JSONValue]? = nil,
        isPrimary: Bool = false,
        isDefault: Bool = false,
        hasAvatar: Bool = false
    ) throws -> RosterProfile {
        var uiMeta: [String: JSONValue] = ["other-ns": Self.foreignNamespace]
        if let bot { uiMeta[BotMeta.namespace] = .object(bot) }
        var row: [String: JSONValue] = [
            "name": .string(name),
            "ui_meta": .object(uiMeta),
            "is_primary": .bool(isPrimary),
            "is_default": .bool(isDefault),
            "has_avatar": .bool(hasAvatar),
        ]
        if let displayName { row["display_name"] = .string(displayName) }
        return try #require(RosterProfile(.object(row)))
    }

    private func effective(_ profile: RosterProfile) throws -> (root: [String: JSONValue], bot: [String: JSONValue]) {
        let root = try #require(LooklessFill.effectiveUIMeta(for: profile, palette: Self.palette)?.objectValue)
        return (root, root[BotMeta.namespace]?.objectValue ?? [:])
    }

    @Test(arguments: ["atlas", "hermes-fork-sync", "a", "bot_2", "9lives"], [false, true])
    func aLooklessBotKeepsEverythingItHadAndGainsAWholeLook(name: String, hasTitle: Bool) throws {
        var original = Self.unrelatedFields
        if hasTitle { original["title"] = "Ada the Great" }
        let subject = try profile(name, displayName: "Display Name", bot: original)

        let (root, bot) = try effective(subject)

        #expect(root["other-ns"] == Self.foreignNamespace)
        #expect(Set(root.keys) == ["other-ns", BotMeta.namespace])
        for (key, value) in original { #expect(bot[key] == value, "\(key) survives the fill") }
        #expect(Set(bot.keys).subtracting(original.keys).isSubset(of: Self.lookKeys.union(["title"])))

        #expect(!subject.resolvedDisplayName.isEmpty)
        let title = try #require(bot["title"]?.stringValue)
        #expect(!title.isEmpty)
        #expect(title == (hasTitle ? "Ada the Great" : "Display Name"))

        let shape = try #require(bot["shape"]?.stringValue)
        let prefix = "blobatar:\(name):"
        #expect(shape.hasPrefix(prefix))
        #expect(Self.palette.kinds.contains(String(shape.dropFirst(prefix.count))))
        #expect(Self.palette.colors.contains(try #require(bot["color"]?.stringValue)))
        #expect(bot["custom"] == true)
        #expect(bot["imageKind"] == "shape")

        let filled = BotMeta(fields: bot)
        #expect(!LooklessFill.isLookless(filled))
        #expect(filled.shape == shape)
    }

    @Test func aLooklessBotWithNoTitleAndNoDisplayNameIsTitledFromItsSlug() throws {
        let subject = try profile("hermes-fork-sync", bot: [:])
        let (_, bot) = try effective(subject)
        #expect(bot["title"] == "Hermes Fork Sync")
        #expect(subject.resolvedDisplayName == "Hermes Fork Sync")
    }

    @Test func aBlankTitleCountsAsNoTitle() throws {
        let (_, bot) = try effective(try profile("atlas", bot: ["title": "   ", "pinned": true]))
        #expect(bot["title"] == "Atlas")
        #expect(bot["pinned"] == true)
    }

    @Test func aStaleCustomFlagIsOverwrittenSoTheFilledColourIsHonoured() throws {
        let (_, bot) = try effective(try profile("atlas", bot: ["custom": false, "image": "", "imageKind": "shape"]))
        #expect(bot["custom"] == true)
        #expect(bot["image"] == "")
        #expect(bot["shape"]?.stringValue?.hasPrefix("blobatar:atlas:") == true)
    }

    @Test func theFillIsStableWhenItsOwnOutputIsFedBack() throws {
        let first = try profile("atlas", bot: Self.unrelatedFields)
        let (root, _) = try effective(first)
        let second = try #require(RosterProfile(.object(["name": "atlas", "ui_meta": .object(root)])))
        #expect(LooklessFill.effectiveUIMeta(for: second, palette: Self.palette) == second.uiMeta)
    }

    @Test(arguments: [
        ["shape": "blobatar:ab:cloud"],
        ["color": "#10dc69"],
        ["shape": "blobatar:ab:cloud", "color": "#10dc69", "custom": true],
        ["imageKind": "photo", "image": "data:image/png;base64,AAAA"],
        ["image": "data:image/png;base64,AAAA"],
    ] as [[String: JSONValue]])
    func aBotThatAlreadyHasALookIsReturnedUntouched(bot: [String: JSONValue]) throws {
        let subject = try profile("atlas", bot: bot.merging(Self.unrelatedFields) { current, _ in current })
        #expect(LooklessFill.effectiveUIMeta(for: subject, palette: Self.palette) == subject.uiMeta)
    }

    @Test func aBotWithAnUploadedAvatarIsReturnedUntouched() throws {
        let subject = try profile("atlas", bot: Self.unrelatedFields, hasAvatar: true)
        #expect(LooklessFill.effectiveUIMeta(for: subject, palette: Self.palette) == subject.uiMeta)
    }

    @Test(arguments: [("lead", true, false), ("anything", false, true), ("default", false, false), ("Default", false, false)])
    func thePrimaryAndTheDefaultBotAreReturnedUntouched(name: String, isPrimary: Bool, isDefault: Bool) throws {
        let subject = try profile(name, bot: Self.unrelatedFields, isPrimary: isPrimary, isDefault: isDefault)
        #expect(LooklessFill.effectiveUIMeta(for: subject, palette: Self.palette) == subject.uiMeta)
    }

    @Test func aLooklessBotWithNoUIMetaAtAllStillGetsAFullLook() throws {
        let subject = try #require(RosterProfile(.object(["name": "atlas"])))
        let root = try #require(LooklessFill.effectiveUIMeta(for: subject, palette: Self.palette)?.objectValue)
        let bot = try #require(root[BotMeta.namespace]?.objectValue)
        #expect(Set(root.keys) == [BotMeta.namespace])
        #expect(Set(bot.keys) == Self.lookKeys.union(["title"]))
        #expect(bot["title"] == "Atlas")
    }
}
