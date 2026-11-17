import Foundation
import PalConnect
import PalDiagnostics
import PalProtocol
import PalTransport
import Testing

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
            hubInstalled: [
                HubInstalledSkill(name: "weather", identifier: "official/weather"),
                HubInstalledSkill(name: "notes", identifier: "acme/skills/notes"),
            ],
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
