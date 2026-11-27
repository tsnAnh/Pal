import Foundation
import Testing

@testable import PalBotProfile
@testable import PalProtocol
@testable import PalRoster
@testable import PalTransport

private let digest = String(repeating: "ab", count: 32)
private let canary = "canary-template-5d2"
private let templateBytes = Data("CANARY-TEMPLATE-BYTES-0001".utf8)

private func review(extra: [String: JSONValue] = [:]) -> JSONValue {
    var review: [String: JSONValue] = [:]
    review["format_version"] = 1
    review["digest"] = .string(digest)
    review["size"] = 321
    review["display_name"] = "Nova"
    review["description"] = "Helps with research"
    review["suggested_name"] = "nova"
    review["suggested_display_name"] = "Nova"
    review["soul"] = "private persona text"
    review["model"] = ["provider": "anthropic", "default": "claude-a"]
    review["toolsets"] = ["web"]
    let notes: JSONValue = ["name": "notes", "files": 2]
    let scraper: JSONValue = ["name": "scraper"]
    review["skills"] = .array([notes, scraper])
    let calendar: JSONValue = ["name": "calendar", "needs": ["CAL_TOKEN"]]
    review["mcp_servers"] = .array([calendar])
    let morning: JSONValue = ["name": "Morning", "schedule": "0 8 * * *", "prompt": "do it"]
    review["routines"] = .array([morning])
    review["skipped_routines"] = ["Broken"]
    review["has_avatar"] = true
    for (key, value) in extra { review[key] = value }
    return ["dry_run": true, "review": .object(review)]
}

private let created: JSONValue = [
    "dry_run": false, "review": .null, "name": "nova", "display_name": "Nova", "path": "/srv/hermes/profiles/nova",
]

private func failing(_ code: Int, message: String = canary) -> @Sendable ([String: JSONValue]) throws -> JSONValue {
    { _ in throw GatewayTransportError.rpc(RPCError(code: code, message: message, data: ["detail": .string(message)])) }
}

@MainActor
@Suite("Template import")
struct TemplateImportTests {
    private func model(_ bots: ScriptedBots) -> TemplateImportModel {
        TemplateImportModel(client: TemplateImportClient(gateway: bots.gateway))
    }

    @Test("dry run then commit send exactly the contract params and return the created bot")
    func flow() async throws {
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review())
        bots.script("profiles.template.import", created)
        let importer = model(bots)
        await importer.begin(templateBytes)
        #expect(importer.phase == .reviewing)
        let reviewed = try #require(importer.review)
        #expect(reviewed.digest == digest)
        #expect(reviewed.skills == ["notes", "scraper"])
        #expect(reviewed.connections == ["calendar"])
        #expect(reviewed.routines == ["Morning"])
        #expect(reviewed.skippedRoutines == 1)
        #expect(reviewed.model == "anthropic/claude-a")
        #expect(reviewed.hasPersona && reviewed.hasAvatar)
        #expect(importer.name == "Nova")
        let bot = await importer.confirm()
        #expect(bot == ImportedBot(name: "nova", displayName: "Nova"))
        #expect(importer.phase == .imported(ImportedBot(name: "nova", displayName: "Nova")))
        let calls = bots.calls(to: "profiles.template.import")
        #expect(calls.map(\.params) == [
            ["data": .string(templateBytes.base64EncodedString()), "dry_run": true],
            ["data": .string(templateBytes.base64EncodedString()), "reviewed_digest": .string(digest)],
        ])
        #expect(bots.calls.count == 2)
    }

    @Test("routine names in a template review read as natural language")
    func reviewedRoutineNames() async throws {
        let bots = ScriptedBots()
        let slug: JSONValue = ["name": "weekly_news_digest"]
        let id: JSONValue = ["name": "3f9a2c1d4e5b6a7f"]
        bots.script("profiles.template.import", review(extra: ["routines": .array([slug, id])]))
        let importer = model(bots)
        await importer.begin(templateBytes)
        #expect(try #require(importer.review).routines == ["Weekly news digest", "Untitled routine"])
    }

    @Test("an edited name is sent as name and display_name")
    func editedName() async {
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review())
        bots.script("profiles.template.import", created)
        let importer = model(bots)
        await importer.begin(templateBytes)
        importer.name = "Nova Two"
        _ = await importer.confirm()
        let identity = BotIdentity(entered: "Nova Two")
        let commit = bots.calls(to: "profiles.template.import").last?.params
        #expect(commit?["name"] == .string(identity.slug))
        #expect(commit?["display_name"] == .string("Nova Two"))
    }

    @Test("an invalid name blocks the import without a call")
    func invalidName() async {
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review())
        let importer = model(bots)
        await importer.begin(templateBytes)
        importer.name = "!!!"
        #expect(!importer.canImport)
        #expect(await importer.confirm() == nil)
        #expect(bots.calls.count == 1)
    }

    @Test("error codes map to plain messages")
    func errorMapping() async {
        let table: [(Int, TemplateImportError)] = [
            (4071, .invalidFile), (4072, .changedAfterReview), (4073, .nameUnavailable), (4074, .unsupportedVersion),
            (4075, .tooLarge), (4076, .unreadable), (5071, .unavailable), (4001, .unavailable),
        ]
        for (code, expected) in table {
            let bots = ScriptedBots()
            bots.script("profiles.template.import", failing(code))
            let importer = model(bots)
            await importer.begin(templateBytes)
            #expect(importer.failure == expected)
            #expect(importer.phase == .idle)
            #expect(!expected.message.contains(canary))
            #expect(!expected.message.isEmpty)
        }
        let denied = ScriptedBots()
        denied.script("profiles.template.import") { _ in
            throw GatewayTransportError.rpc(RPCError(code: 4003, message: canary, data: ["reason": "permission_denied"]))
        }
        let importer = model(denied)
        await importer.begin(templateBytes)
        #expect(importer.failure == .permissionDenied)
    }

    @Test("a failed commit leaves state unchanged, keeps the review and a retry succeeds")
    func retry() async {
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review())
        bots.script("profiles.template.import", failing(4073))
        bots.script("profiles.template.import", created)
        let importer = model(bots)
        await importer.begin(templateBytes)
        #expect(await importer.confirm() == nil)
        #expect(importer.phase == .reviewing)
        #expect(importer.failure == .nameUnavailable)
        #expect(importer.review?.digest == digest)
        importer.name = "Nova Three"
        #expect(importer.failure == nil)
        #expect(await importer.confirm() != nil)
        #expect(bots.calls.allSatisfy { $0.method == "profiles.template.import" })
        #expect(bots.calls.count == 3)
    }

    @Test("a template that changed after review drops back to idle and can be chosen again")
    func changedAfterReview() async {
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review())
        bots.script("profiles.template.import", failing(4072))
        bots.script("profiles.template.import", review())
        let importer = model(bots)
        await importer.begin(templateBytes)
        #expect(await importer.confirm() == nil)
        #expect(importer.phase == .idle)
        #expect(importer.review == nil)
        #expect(importer.failure == .changedAfterReview)
        await importer.begin(templateBytes)
        #expect(importer.phase == .reviewing)
        #expect(importer.failure == nil)
    }

    @Test("malformed or wrong-shaped replies fail without creating anything")
    func malformedReplies() async {
        for reply: JSONValue in [
            ["dry_run": false, "name": "nova"],
            ["dry_run": true],
            ["dry_run": true, "review": ["size": 1]],
            ["dry_run": true, "review": ["digest": "  "]],
            "nope",
        ] {
            let bots = ScriptedBots()
            bots.script("profiles.template.import", reply)
            let importer = model(bots)
            await importer.begin(templateBytes)
            #expect(importer.failure == .unavailable)
            #expect(importer.phase == .idle)
        }
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review())
        bots.script("profiles.template.import", ["dry_run": false])
        let importer = model(bots)
        await importer.begin(templateBytes)
        #expect(await importer.confirm() == nil)
        #expect(importer.failure == .unavailable)
        #expect(importer.phase == .reviewing)
    }

    @Test("an empty file is refused locally")
    func emptyFile() async {
        let bots = ScriptedBots()
        let importer = model(bots)
        await importer.begin(Data())
        #expect(importer.failure == .unreadable)
        #expect(bots.calls.isEmpty)
    }

    @Test("a canary in errors, extra reply fields and the file bytes never reaches surfaced state")
    func canaryNotDisclosed() async {
        let bots = ScriptedBots()
        bots.script("profiles.template.import", review(extra: ["api_key": .string(canary), "look": ["note": .string(canary)]]))
        bots.script("profiles.template.import", failing(5071))
        let importer = model(bots)
        await importer.begin(templateBytes)
        let reviewing = "\(importer.phase) \(String(describing: importer.review)) \(String(describing: importer.failure)) \(importer.name)"
        #expect(!reviewing.contains(canary))
        #expect(await importer.confirm() == nil)
        let failed = "\(importer.phase) \(String(describing: importer.failure)) \(importer.failure?.message ?? "")"
        #expect(!failed.contains(canary))
        let everything = reviewing + failed
        #expect(!everything.contains("CANARY-TEMPLATE-BYTES"))
        #expect(!everything.contains(templateBytes.base64EncodedString()))
        #expect(!everything.contains("private persona text"))
        let dryRunFailure = ScriptedBots()
        dryRunFailure.script("profiles.template.import", failing(4071))
        let second = model(dryRunFailure)
        await second.begin(templateBytes)
        let surfaced = "\(second.phase) \(String(describing: second.failure)) \(second.failure?.message ?? "")"
        #expect(!surfaced.contains(canary) && !surfaced.contains("CANARY-TEMPLATE-BYTES"))
    }
}
