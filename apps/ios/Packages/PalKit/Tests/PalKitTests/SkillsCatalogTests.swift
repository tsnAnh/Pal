import Foundation
import PalConnect
import PalDiagnostics
import PalProtocol
import PalTransport
import Testing

private func gatewayFailure(_ code: Int, log: String? = nil, reason: String? = nil) -> CustomRPC.Reply {
    { _ in
        var data: [String: JSONValue] = [:]
        if let log { data["log"] = .string(log) }
        if let reason { data["reason"] = .string(reason) }
        throw GatewayTransportError.rpc(RPCError(code: code, message: "secret internal detail", data: data.isEmpty ? nil : .object(data)))
    }
}

private func skillsService(_ rpc: CustomRPC, profile: String? = "alpha") -> SkillsCatalogService {
    SkillsCatalogService(rpc: rpc, profile: profile)
}

private func manageParams(_ rpc: CustomRPC, action: String) -> [JSONValue] {
    rpc.params("skills.manage").filter { $0["action"]?.stringValue == action }
}

private let ok: CustomRPC.Reply = { _ in ["ok": true] }

private let hubItems = [
    SkillHubItem(name: "pdf-tools", summary: "Merge and split PDFs", source: "github", trust: "community", identifier: "acme/skills/pdf-tools"),
    SkillHubItem(name: "weather", summary: "Forecasts", source: "official", trust: "trusted", identifier: "official/weather"),
    SkillHubItem(name: "notes", summary: "Take notes", source: "github", trust: "community", identifier: "acme/skills/notes"),
]

@Suite("Skills catalog state")
struct SkillsCatalogStateTests {
    @Test func aSkillOnlyInTheHubIsAvailable() {
        let catalog = SkillsCatalog(hub: hubItems, state: .empty)
        #expect(catalog.rows.allSatisfy { $0.state == .available && !$0.isRemovable })
    }

    @Test func aHubInstalledSkillIsInstalledAndRemovableAndMatchesByIdentifier() {
        let state = SkillsInstallState(hubInstalled: [HubInstalledSkill(name: "weather", identifier: "official/weather")])
        let row = SkillsCatalog(hub: hubItems, state: state).rows.first { $0.name == "weather" }
        #expect(row?.state == .installed)
        #expect(row?.isRemovable == true)
        #expect(row?.managedName == "weather")
    }

    @Test func sameNameWithADifferentIdentifierIsNotInstalled() {
        let state = SkillsInstallState(hubInstalled: [HubInstalledSkill(name: "weather", identifier: "other/weather")])
        let rows = SkillsCatalog(hub: hubItems, state: state).rows
        #expect(rows.first { $0.identifier == "official/weather" }?.state == .available)
        #expect(rows.contains { $0.identifier == "other/weather" && $0.state == .installed })
    }

    @Test func anUpdateAvailableStatusMarksOnlyThatSkill() {
        let state = SkillsInstallState(
            hubInstalled: [HubInstalledSkill(name: "weather", identifier: "official/weather"), HubInstalledSkill(name: "notes", identifier: "acme/skills/notes")],
            updates: [
                SkillUpdateStatus(name: "weather", identifier: "official/weather", status: "update_available"),
                SkillUpdateStatus(name: "notes", identifier: "acme/skills/notes", status: "up_to_date"),
            ]
        )
        let catalog = SkillsCatalog(hub: hubItems, state: state)
        #expect(catalog.rows.first { $0.name == "weather" }?.state == .updateAvailable)
        #expect(catalog.rows.first { $0.name == "notes" }?.state == .installed)
        #expect(catalog.updatableCount == 1)
    }

    @Test func orphanedAndInvalidInstallsAreNotOfferedAnUpdate() {
        let state = SkillsInstallState(
            hubInstalled: [HubInstalledSkill(name: "a"), HubInstalledSkill(name: "b")],
            updates: [SkillUpdateStatus(name: "a", status: "orphaned"), SkillUpdateStatus(name: "b", status: "invalid_install")]
        )
        #expect(SkillsCatalog(state: state).rows.allSatisfy { $0.state == .installed })
    }

    @Test func hubInstalledSkillsOutsideTheLoadedPageStillAppear() {
        let state = SkillsInstallState(hubInstalled: [HubInstalledSkill(name: "ghost", identifier: "x/ghost")])
        let rows = SkillsCatalog(hub: hubItems, state: state).rows
        #expect(rows.count == hubItems.count + 1)
        #expect(rows.last?.name == "ghost" && rows.last?.isRemovable == true)
    }

    @Test func bundledSkillsShowAsInstalledWithoutARemoveAction() {
        let state = SkillsInstallState(bundled: [InstalledSkill(name: "findmy", category: "apple")])
        let row = SkillsCatalog(state: state).rows.first
        #expect(row?.state == .installed)
        #expect(row?.isRemovable == false)
    }

    @Test func aBundledSkillSharingAHubNameIsNotListedTwice() {
        let state = SkillsInstallState(bundled: [InstalledSkill(name: "Weather", category: "web")])
        #expect(SkillsCatalog(hub: hubItems, state: state).rows.filter { $0.name.lowercased() == "weather" }.count == 1)
    }

    @Test func duplicateRowsCollapse() {
        let twice = hubItems + hubItems
        #expect(SkillsCatalog(hub: twice, state: .empty).rows.count == hubItems.count)
    }
}

@Suite("Skills catalog filter and search")
struct SkillsCatalogFilterTests {
    private let state = SkillsInstallState(
        hubInstalled: [HubInstalledSkill(name: "weather", identifier: "official/weather"), HubInstalledSkill(name: "notes", identifier: "acme/skills/notes")],
        updates: [SkillUpdateStatus(name: "notes", identifier: "acme/skills/notes", status: "update_available")]
    )

    @Test func filtersSplitInstalledAndUpdates() {
        let catalog = SkillsCatalog(hub: hubItems, state: state)
        #expect(catalog.rows(filter: .all).count == 3)
        #expect(Set(catalog.rows(filter: .installed).map(\.name)) == ["weather", "notes"])
        #expect(catalog.rows(filter: .updates).map(\.name) == ["notes"])
    }

    @Test func textMatchesNameSummaryAndSourceIgnoringCase() {
        let catalog = SkillsCatalog(hub: hubItems, state: .empty)
        #expect(catalog.rows(filter: .all, query: "PDF").map(\.name) == ["pdf-tools"])
        #expect(catalog.rows(filter: .all, query: "forecast").map(\.name) == ["weather"])
        #expect(Set(catalog.rows(filter: .all, query: "github").map(\.name)) == ["pdf-tools", "notes"])
        #expect(catalog.rows(filter: .all, query: "  ").count == 3)
        #expect(catalog.rows(filter: .all, query: "zzz").isEmpty)
    }

    @Test func filterAndTextCombine() {
        let catalog = SkillsCatalog(hub: hubItems, state: state)
        #expect(catalog.rows(filter: .installed, query: "note").map(\.name) == ["notes"])
        #expect(catalog.rows(filter: .updates, query: "weather").isEmpty)
    }

    @Test func remoteHitsCarryInstalledStateAndLocalMatchesAreMerged() {
        let catalog = SkillsCatalog(hub: hubItems, state: state)
        let remote = [SkillHubItem(name: "weather", summary: "Forecasts"), SkillHubItem(name: "storm-radar", summary: "Radar")]
        let rows = catalog.results(for: "storm", filter: .all, remote: remote)
        #expect(rows.map(\.name) == ["weather", "storm-radar"])
        #expect(rows.first?.state == .installed)
        #expect(rows.last?.state == .available)
    }

    @Test func searchingNeverListsTheSameSkillTwiceOrUnrelatedInstalledOnes() {
        let catalog = SkillsCatalog(hub: hubItems, state: state)
        let rows = catalog.results(for: "notes", filter: .all, remote: [SkillHubItem(name: "notes", summary: "Take notes")])
        #expect(rows.map(\.name) == ["notes"])
    }

    @Test func aBlankQueryFallsBackToTheBrowsedRows() {
        let catalog = SkillsCatalog(hub: hubItems, state: state)
        #expect(catalog.results(for: " ", filter: .updates, remote: []).map(\.name) == ["notes"])
    }
}

@Suite("Skill requirements")
struct SkillRequirementsTests {
    @Test func readsEnvironmentVariablesWithPromptHelpAndOptional() {
        let markdown = """
        ---
        name: youtube
        required_environment_variables:
          - name: YOUTUBE_API_KEY
            prompt: YouTube Data API v3 key
            help: "Create one at https://console.example.com/keys"
            optional: true
          - name: SECOND_TOKEN
        metadata:
          x: 1
        ---
        # Body
        required_environment_variables:
          - name: IGNORED
        """
        let requirements = SkillRequirements.parse(skillMarkdown: markdown)
        #expect(requirements.environment.map(\.name) == ["YOUTUBE_API_KEY", "SECOND_TOKEN"])
        #expect(requirements.environment[0].prompt == "YouTube Data API v3 key")
        #expect(requirements.environment[0].help == "Create one at https://console.example.com/keys")
        #expect(requirements.environment[0].isOptional)
        #expect(!requirements.environment[1].isOptional)
        #expect(requirements.needsSecrets)
    }

    @Test func readsPrerequisitesEnvVarsAndCommands() {
        let markdown = """
        ---
        prerequisites:
          env_vars: [MSGRAPH_TENANT_ID, "MSGRAPH_CLIENT_ID"]
          commands: [hermes, remindctl]
        ---
        """
        let requirements = SkillRequirements.parse(skillMarkdown: markdown)
        #expect(requirements.environment.map(\.name) == ["MSGRAPH_TENANT_ID", "MSGRAPH_CLIENT_ID"])
        #expect(requirements.commands == ["hermes", "remindctl"])
    }

    @Test func readsBlockListsAndScalarItems() {
        let markdown = "---\nrequired_environment_variables:\n- API_KEY\n- OTHER_KEY\nrequired_commands:\n  - ffmpeg\n---\n"
        let requirements = SkillRequirements.parse(skillMarkdown: markdown)
        #expect(requirements.environment.map(\.name) == ["API_KEY", "OTHER_KEY"])
        #expect(requirements.commands == ["ffmpeg"])
    }

    @Test func onlyOptionalKeysDoNotNeedSecrets() {
        let markdown = "---\nrequired_environment_variables:\n  - name: K\n    optional: yes\n---\n"
        let requirements = SkillRequirements.parse(skillMarkdown: markdown)
        #expect(requirements.environment.count == 1)
        #expect(!requirements.needsSecrets)
    }

    @Test(arguments: [
        "", "no frontmatter at all", "---\n", "---\nrequired_environment_variables:\n", "---\nrequired_environment_variables: [\n---",
        "---\nrequired_environment_variables:\n  - name: not a valid name!\n  - name: 9STARTS_WITH_DIGIT\n---",
        "\u{FEFF}---\n:::\n- - -\n---", "---\nprerequisites:\n---",
    ])
    func malformedInputNeverThrowsAndYieldsNothingInvalid(_ text: String) {
        let requirements = SkillRequirements.parse(skillMarkdown: text)
        #expect(requirements.environment.allSatisfy { $0.name.first.map { $0.isLetter || $0 == "_" } ?? false })
    }

    @Test func aTruncatedPreviewKeepsWhatWasRead() {
        let markdown = "---\nrequired_environment_variables:\n  - name: KEEP_ME\n    prompt: half a sen"
        #expect(SkillRequirements.parse(skillMarkdown: markdown).environment.map(\.name) == ["KEEP_ME"])
    }

    @Test func duplicatesCollapse() {
        let markdown = "---\nrequired_environment_variables:\n  - name: A_KEY\n  - name: A_KEY\nprerequisites:\n  env_vars: [A_KEY]\n  commands: [x, x]\n---"
        let requirements = SkillRequirements.parse(skillMarkdown: markdown)
        #expect(requirements.environment.count == 1)
        #expect(requirements.commands == ["x"])
    }

    @Test func crlfLineEndingsParse() {
        let markdown = "---\r\nrequired_environment_variables:\r\n  - name: WIN_KEY\r\n---\r\n"
        #expect(SkillRequirements.parse(skillMarkdown: markdown).environment.map(\.name) == ["WIN_KEY"])
    }
}

@Suite("Skills catalog service")
struct SkillsCatalogServiceTests {
    @Test func browseSendsPageAndProfileAndParsesRowsSkippingMalformedOnes() async throws {
        let rpc = CustomRPC(["skills.manage": { _ in
            ["items": [["name": "a", "description": "A", "source": "github", "identifier": "o/a"], ["description": "no name"], ["name": "  "]], "page": 2, "total_pages": 3]
        }])
        let page = try await skillsService(rpc).browse(page: 2)
        #expect(page.items == [SkillHubItem(name: "a", summary: "A", source: "github", identifier: "o/a")])
        #expect(page.page == 2 && page.totalPages == 3 && page.hasMore)
        let sent = manageParams(rpc, action: "browse").first
        #expect(sent?["profile"]?.stringValue == "alpha")
        #expect(sent?["page"]?.intValue == 2)
    }

    @Test func searchSendsTheTrimmedQueryAndSkipsBlankOnes() async throws {
        let rpc = CustomRPC(["skills.manage": { _ in ["results": [["name": "pdf", "description": "PDFs"]]] }])
        let hits = try await skillsService(rpc).search("  pdf ")
        #expect(hits.map(\.name) == ["pdf"] && hits.first?.identifier == nil)
        #expect(manageParams(rpc, action: "search").first?["query"]?.stringValue == "pdf")
        #expect(try await skillsService(rpc).search("   ").isEmpty)
        #expect(manageParams(rpc, action: "search").count == 1)
    }

    @Test func inspectParsesDetailAndRequirements() async throws {
        let rpc = CustomRPC(["skills.manage": { _ in
            ["info": ["name": "yt", "description": "Video", "source": "github", "identifier": "o/yt", "tags": ["video"],
                      "skill_md_preview": "---\nrequired_environment_variables:\n  - name: YT_KEY\nprerequisites:\n  commands: [ffmpeg]\n---\n"]]
        }])
        let detail = try await skillsService(rpc).inspect("o/yt")
        #expect(detail.name == "yt" && detail.tags == ["video"] && detail.identifier == "o/yt")
        #expect(detail.requirements.environment.map(\.name) == ["YT_KEY"])
        #expect(detail.requirements.commands == ["ffmpeg"])
        #expect(manageParams(rpc, action: "inspect").first?["query"]?.stringValue == "o/yt")
    }

    @Test func inspectOfAnUnknownIdentifierIsNotFound() async {
        let rpc = CustomRPC(["skills.manage": { _ in ["info": [:]] }])
        await #expect(throws: SkillsCatalogError.notFound) { try await skillsService(rpc).inspect("nope") }
    }

    @Test func installStateCombinesInstalledBundledAndUpdates() async throws {
        let rpc = CustomRPC(["skills.manage": { params in
            switch params["action"]?.stringValue {
            case "installed": return ["installed_skills": [["name": "weather", "identifier": "official/weather", "source": "official", "trust_level": "trusted", "install_path": "/secret/path"]]]
            case "list": return ["skills": ["apple": ["findmy"]]]
            case "check": return ["updates": [["name": "weather", "identifier": "official/weather", "status": "update_available"]]]
            default: return [:]
            }
        }])
        let state = try await skillsService(rpc).installState()
        #expect(state.hubInstalled.map(\.name) == ["weather"])
        #expect(state.bundled.map(\.name) == ["findmy"])
        #expect(state.updates.map(\.status) == ["update_available"])
        #expect(SkillsCatalog(hub: hubItems, state: state).rows.first { $0.name == "weather" }?.state == .updateAvailable)
    }

    @Test func aFailedUpdateCheckStillReturnsWhatIsInstalled() async throws {
        let rpc = CustomRPC(["skills.manage": { params in
            switch params["action"]?.stringValue {
            case "installed": return ["installed_skills": [["name": "weather"]]]
            default: throw GatewayTransportError.timedOut
            }
        }])
        let state = try await skillsService(rpc).installState()
        #expect(state.hubInstalled.map(\.name) == ["weather"] && state.updates.isEmpty && state.bundled.isEmpty)
    }

    @Test func aFailedInstalledReadFailsTheLoadInsteadOfGuessingAvailable() async {
        let rpc = CustomRPC(["skills.manage": { params in
            if params["action"]?.stringValue == "installed" { throw GatewayTransportError.timedOut }
            return [:]
        }])
        await #expect(throws: SkillsCatalogError.unavailable) { try await skillsService(rpc).installState() }
    }

    @Test func installSendsTheIdentifierWithProfileThenReloadsTheAgent() async throws {
        let rpc = CustomRPC(["skills.manage": ok, "skills.reload": ok])
        try await skillsService(rpc).install("official/weather")
        let sent = manageParams(rpc, action: "install").first
        #expect(sent?["query"]?.stringValue == "official/weather")
        #expect(sent?["profile"]?.stringValue == "alpha")
        #expect(rpc.methods() == ["skills.manage", "skills.reload"])
        #expect(rpc.params("skills.reload").first?["profile"]?.stringValue == "alpha")
    }

    @Test func updateOneSendsTheNameAndUpdateAllSendsNoQuery() async throws {
        let rpc = CustomRPC(["skills.manage": ok, "skills.reload": ok])
        try await skillsService(rpc).update(name: "weather")
        try await skillsService(rpc).update(name: nil)
        let sent = manageParams(rpc, action: "update")
        #expect(sent.count == 2)
        #expect(sent[0]["query"]?.stringValue == "weather")
        #expect(sent[1]["query"]?.stringValue == nil)
        #expect(sent.allSatisfy { $0["profile"]?.stringValue == "alpha" })
        #expect(rpc.params("skills.reload").count == 2)
    }

    @Test func uninstallSendsTheNameAndProfile() async throws {
        let rpc = CustomRPC(["skills.manage": ok, "skills.reload": ok])
        try await skillsService(rpc).uninstall(name: "weather")
        let sent = manageParams(rpc, action: "uninstall").first
        #expect(sent?["query"]?.stringValue == "weather")
        #expect(sent?["profile"]?.stringValue == "alpha")
    }

    @Test func noProfileMeansNoProfileKey() async throws {
        let rpc = CustomRPC(["skills.manage": ok, "skills.reload": ok])
        try await skillsService(rpc, profile: nil).uninstall(name: "weather")
        #expect(manageParams(rpc, action: "uninstall").first?["profile"]?.stringValue == nil)
    }

    @Test func blankTargetsAreRejectedBeforeAnyCall() async {
        let rpc = CustomRPC(["skills.manage": ok, "skills.reload": ok])
        await #expect(throws: SkillsCatalogError.invalidRequest) { try await skillsService(rpc).install("  ") }
        await #expect(throws: SkillsCatalogError.invalidRequest) { try await skillsService(rpc).uninstall(name: "") }
        await #expect(throws: SkillsCatalogError.invalidRequest) { try await skillsService(rpc).update(name: " ") }
        await #expect(throws: SkillsCatalogError.invalidRequest) { try await skillsService(rpc).inspect("") }
        #expect(rpc.methods().isEmpty)
    }

    @Test func aFailedMutationDoesNotReloadTheAgent() async {
        let rpc = CustomRPC(["skills.manage": gatewayFailure(5031, log: "boom"), "skills.reload": ok])
        await #expect(throws: SkillsCatalogError.installFailed) { try await skillsService(rpc).install("x/y") }
        #expect(rpc.params("skills.reload").isEmpty)
    }

    @Test func aFailedReloadDoesNotFailASuccessfulInstall() async throws {
        let rpc = CustomRPC(["skills.manage": ok, "skills.reload": gatewayFailure(5000)])
        try await skillsService(rpc).install("x/y")
    }
}

@Suite("Skills error mapping")
struct SkillsErrorMappingTests {
    private func failure(_ reply: @escaping CustomRPC.Reply, _ work: (SkillsCatalogService) async throws -> Void) async -> SkillsCatalogError? {
        let rpc = CustomRPC(["skills.manage": reply, "skills.reload": ok])
        do { try await work(skillsService(rpc)) } catch { return error as? SkillsCatalogError }
        return nil
    }

    @Test func installBlockedByTheScannerIsDistinctFromAFailedFetch() async {
        let blocked = await failure(gatewayFailure(5031, log: "Installation blocked: dangerous verdict")) { try await $0.install("a/b") }
        let failed = await failure(gatewayFailure(5031, log: "fetch failed: 404")) { try await $0.install("a/b") }
        let bare = await failure(gatewayFailure(5031)) { try await $0.install("a/b") }
        #expect(blocked == .installBlocked)
        #expect(failed == .installFailed)
        #expect(bare == .installFailed)
    }

    @Test func updateAndUninstallFailuresMap() async {
        let update = await failure(gatewayFailure(5032)) { try await $0.update(name: nil) }
        let uninstall = await failure(gatewayFailure(5033)) { try await $0.uninstall(name: "x") }
        let invalid = await failure(gatewayFailure(4003)) { try await $0.uninstall(name: "x") }
        #expect(update == .updateFailed)
        #expect(uninstall == .uninstallFailed)
        #expect(invalid == .invalidRequest)
    }

    @Test func aMissingNousSignInMapsToSignIn() async {
        let result = await failure(gatewayFailure(5000, reason: "needs_nous_auth")) { try await $0.install("a/b") }
        #expect(result == .signInRequired)
    }

    @Test func transportAndUnknownFailuresAreUnavailable() async {
        let timedOut = await failure({ _ in throw GatewayTransportError.timedOut }) { try await $0.install("a/b") }
        let unknown = await failure(gatewayFailure(-32601)) { try await $0.update(name: nil) }
        #expect(timedOut == .unavailable)
        #expect(unknown == .unavailable)
    }

    @Test func userMessagesLeakNoInternals() {
        let all: [SkillsCatalogError] = [.signInRequired, .installBlocked, .installFailed, .updateFailed, .uninstallFailed, .notFound, .invalidRequest, .unavailable]
        for error in all {
            let text = error.userMessage.lowercased()
            #expect(!text.isEmpty)
            for forbidden in ["rpc", "5031", "5032", "5033", "skills.manage", "gateway", "secret internal detail", "traceback"] {
                #expect(!text.contains(forbidden))
            }
        }
    }
}

@Suite("Skill key saving")
struct SkillKeySavingTests {
    private let saved: CustomRPC.Reply = { _ in ["saved": true, "name": "weather"] }

    private func service(_ rpc: CustomRPC, diagnostics: Diagnostics = .silent) -> SkillsCatalogService {
        SkillsCatalogService(rpc: rpc, profile: "alpha", diagnostics: diagnostics)
    }

    private func failure(_ code: Int, canary: String = "unused") async -> (SkillsCatalogError?, String) {
        let recorder = DiagnosticRecorder()
        let rpc = CustomRPC(["skills.manage": gatewayFailure(code)])
        do {
            try await service(rpc, diagnostics: recorder.diagnostics).setKey(skill: "weather", keyName: "WEATHER_API_KEY", value: SecretString(canary))
        } catch {
            return (error as? SkillsCatalogError, recorder.transcript)
        }
        return (nil, recorder.transcript)
    }

    @Test func notDeclaredOrBadValueMapsToInvalidKey() async {
        #expect(await failure(4101).0 == .invalidKey)
    }

    @Test func unknownSkillMapsToNotFound() async {
        #expect(await failure(4004).0 == .notFound)
    }

    @Test func aWriteFailureMapsToKeyNotSaved() async {
        #expect(await failure(5034).0 == .keyNotSaved)
    }

    @Test func transportFailureIsUnavailable() async {
        let rpc = CustomRPC(["skills.manage": { _ in throw GatewayTransportError.timedOut }])
        await #expect(throws: SkillsCatalogError.unavailable) {
            try await service(rpc).setKey(skill: "weather", keyName: "WEATHER_API_KEY", value: SecretString("v"))
        }
    }

    @Test func blankInputsAreRejectedBeforeAnyCall() async {
        let rpc = CustomRPC(["skills.manage": saved])
        await #expect(throws: SkillsCatalogError.invalidRequest) {
            try await service(rpc).setKey(skill: " ", keyName: "K", value: SecretString("v"))
        }
        await #expect(throws: SkillsCatalogError.invalidRequest) {
            try await service(rpc).setKey(skill: "weather", keyName: "", value: SecretString("v"))
        }
        await #expect(throws: SkillsCatalogError.invalidKey) {
            try await service(rpc).setKey(skill: "weather", keyName: "K", value: SecretString(""))
        }
        #expect(rpc.methods().isEmpty)
    }

    @Test func sendsTheActionNamesValueAndProfileAndDoesNotReloadAnything() async throws {
        let canary = "CANARY-\(UUID().uuidString)"
        let rpc = CustomRPC(["skills.manage": saved, "skills.reload": ok])
        try await service(rpc).setKey(skill: "weather", keyName: "WEATHER_API_KEY", value: SecretString(canary))
        let sent = try #require(manageParams(rpc, action: "set_key").first)
        #expect(sent["query"]?.stringValue == "weather")
        #expect(sent["key_name"]?.stringValue == "WEATHER_API_KEY")
        #expect(sent["value"]?.stringValue == canary)
        #expect(sent["profile"]?.stringValue == "alpha")
        #expect(rpc.methods() == ["skills.manage"])
    }

    @Test func theValueNeverReachesDiagnosticsOrErrorText() async {
        let canary = "CANARY-\(UUID().uuidString)"
        for code in [4101, 4004, 5034, 5000] {
            let (error, transcript) = await failure(code, canary: canary)
            #expect(!transcript.contains(canary))
            #expect(!String(describing: error as Any).contains(canary))
            #expect(!(error?.userMessage ?? "").contains(canary))
        }
    }

    @Test func aSuccessfulSaveLogsNothingSecret() async throws {
        let canary = "CANARY-\(UUID().uuidString)"
        let recorder = DiagnosticRecorder()
        let rpc = CustomRPC(["skills.manage": saved])
        try await service(rpc, diagnostics: recorder.diagnostics).setKey(skill: "weather", keyName: "K", value: SecretString(canary))
        #expect(!recorder.transcript.contains(canary))
    }

    @Test func keyMessagesAreFixedAndLeakNoInternals() {
        for error in [SkillsCatalogError.invalidKey, .keyNotSaved] {
            let text = error.userMessage.lowercased()
            #expect(!text.isEmpty)
            for forbidden in ["rpc", "4101", "5034", "skills.manage", "gateway", "traceback", "env"] {
                #expect(!text.contains(forbidden))
            }
        }
    }
}
