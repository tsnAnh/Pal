import Foundation
import PalConnect
import Testing

private func link(_ label: String, _ url: String) -> SetupLink {
    SetupLink(label: label, url: URL(string: url)!)
}

private let addressStep = SetupStep(id: "address", kind: .publicURL, title: "Your Pal's web address", body: "Google sends you back to your Pal.")

private let googleGuide = SetupGuide(steps: [
    addressStep,
    SetupStep(
        id: "console", kind: .openPage, title: "Create a Google sign-in client", body: "In Google Cloud, create an OAuth client ID.",
        links: [link("Open Google Cloud credentials", "https://console.cloud.google.com/apis/credentials")],
        copies: [SetupCopy(label: "Redirect URI", value: "https://pal.example.com/oauth/callback")]
    ),
    SetupStep(
        id: "apis", kind: .openPage, title: "Turn on the Google services", body: "Turn on each service Pal should use.",
        links: [
            link("Gmail", "https://console.cloud.google.com/apis/library/gmail.googleapis.com"),
            link("Drive", "https://console.cloud.google.com/apis/library/drive.googleapis.com"),
        ]
    ),
    SetupStep(
        id: "client", kind: .paste, title: "Paste your client", body: "Copy the client ID and client secret.",
        fields: [
            SetupField(id: "client_id", label: "Client ID", suffix: ".apps.googleusercontent.com"),
            SetupField(id: "client_secret", label: "Client secret", secret: true),
        ],
        check: .googleClient
    ),
])

private let githubGuide = SetupGuide(steps: [
    SetupStep(
        id: "token_page", kind: .openPage, title: "Create a GitHub token", body: "Create a fine-grained token with these permissions.",
        links: [link("Open GitHub token page", "https://github.com/settings/personal-access-tokens/new")],
        copies: [SetupCopy(label: "Token name", value: "Pal")]
    ),
    SetupStep(
        id: "token", kind: .paste, title: "Paste your token", body: "Paste the token GitHub shows once.",
        fields: [SetupField(id: "token", label: "Token", secret: true, prefixes: ["github_pat_", "ghp_"])], check: .githubToken
    ),
])

private let figmaGuide = SetupGuide(steps: [
    SetupStep(id: "address", kind: .publicURL, title: "Your Pal's web address", body: "Figma sends you back to your Pal."),
    SetupStep(
        id: "app", kind: .openPage, title: "Create a Figma app", body: "Create a new app, name it and pick your team.",
        links: [link("Open Figma apps", "https://www.figma.com/developers/apps")],
        copies: [SetupCopy(label: "Redirect URL", value: "https://pal.example.com/mcp/callback")]
    ),
    SetupStep(
        id: "client", kind: .paste, title: "Paste your client", body: "Paste the Client ID and Client secret.",
        fields: [SetupField(id: "client_id", label: "Client ID"), SetupField(id: "client_secret", label: "Client secret", secret: true)]
    ),
])

private let discordGuide = SetupGuide(steps: [
    SetupStep(id: "bot", kind: .openPage, title: "Create your Discord bot", links: [link("Open portal", "https://discord.com/developers/applications")]),
    SetupStep(id: "token", kind: .paste, title: "Paste your bot token", fields: [SetupField(id: "token", label: "Bot token", secret: true)]),
    SetupStep(id: "servers", kind: .serverPicker, title: "Choose the servers Pal may use"),
    SetupStep(id: "access", kind: .access, title: "Choose what Pal may do"),
])

private func google(address: Bool = true, pasteRoute: Bool = false, configured: Bool = false) -> OwnerSetupContext {
    OwnerSetupContext(
        slug: "google-workspace", appName: "Google Workspace", guide: googleGuide, usesClient: true,
        redirectURL: address ? nil : "https://pal.example.com/oauth/callback", includesAddressStep: address, configured: configured,
        pasteRoute: pasteRoute
    )
}

private let github = OwnerSetupContext(slug: "github", appName: "GitHub", guide: githubGuide, usesClient: false)

private let figma = OwnerSetupContext(
    slug: "figma", appName: "Figma", guide: figmaGuide, usesClient: true, redirectURL: "https://pal.example.com/mcp/callback"
)

private func ids(_ context: OwnerSetupContext) -> [String] {
    OwnerSetupFlow.steps(context)?.map(\.id) ?? []
}

@Suite("Owner setup flow")
struct OwnerSetupFlowTests {
    @Test func googleWithTheAddressStepFollowsTheGatewayGuide() {
        #expect(ids(google()) == ["intro", "address", "console", "console-copy", "apis", "client", "signin", "done"])
    }

    @Test func googleWithoutTheAddressStepDropsOnlyThatStep() {
        #expect(ids(google(address: false)) == ["intro", "console", "console-copy", "apis", "client", "signin", "done"])
    }

    @Test func aDeviceThatSignsInByPastingGetsTheCallbackStepBeforeTheEnd() {
        #expect(ids(google(pasteRoute: true)) == ["intro", "address", "console", "console-copy", "apis", "client", "signin", "callback", "done"])
        #expect(!ids(github).contains("callback"))
    }

    @Test func aTokenConnectorHasNoSignInStep() {
        #expect(ids(github) == ["intro", "token_page", "token_page-copy", "token", "done"])
    }

    @Test func thePasteRouteIsIgnoredWithoutAClientSignIn() {
        let context = OwnerSetupContext(slug: "github", appName: "GitHub", guide: githubGuide, usesClient: false, pasteRoute: true)
        #expect(ids(context) == ids(github))
    }

    @Test func theIntroNamesWhatYouDoAndWhatPalDoes() throws {
        let steps = try #require(OwnerSetupFlow.steps(google()))
        let intro = try #require(steps.first)
        #expect(intro.title == "Set up Google Workspace")
        #expect(intro.body == "Google needs you to register Pal once. 6 short steps, about 5 minutes. Pal remembers where you are, on every device.")
        #expect(intro.kind == .intro(
            youDo: "Create an OAuth client in Google Cloud and paste two values.",
            palDoes: "Fills in the address, checks your values, signs you in."
        ))
        #expect(intro.primaryTitle == "Start")
        #expect(!intro.isChecklistRow)
    }

    @Test func theIntroCountsTheStepsThatAreActuallyShown() throws {
        let without = try #require(OwnerSetupFlow.steps(google(address: false)))
        #expect(without[0].body.contains("5 short steps"))
        let token = try #require(OwnerSetupFlow.steps(github))
        #expect(token[0].body == "GitHub needs you to register Pal once. 3 short steps, about 5 minutes. Pal remembers where you are, on every device.")
        #expect(token[0].kind == .intro(youDo: "Create a token in GitHub and paste it.", palDoes: "Checks the token and saves it on your Pal."))
    }

    @Test func anOAuthConnectorWithoutACopyEntryGetsGenericWording() throws {
        let steps = try #require(OwnerSetupFlow.steps(figma))
        #expect(steps[0].kind == .intro(youDo: "Create an app in Figma and paste two values.", palDoes: "Checks your values and signs you in."))
        let open = try #require(steps.first { $0.id == "app" })
        #expect(open.title == "Open Figma developer settings")
        #expect(open.primaryTitle == "Open Figma developer settings")
        #expect(open.skipTitle == "I already have one")
        #expect(open.skipTarget == "client")
        let copy = try #require(steps.first { $0.id == "app-copy" })
        #expect(copy.title == "Create the app")
        #expect(copy.heading == "Create the app and paste the redirect address")
        #expect(copy.body == "Create a new app, name it and pick your team.")
        let paste = try #require(steps.first { $0.id == "client" })
        #expect(paste.heading == "Paste the two values Figma shows")
        #expect(paste.title == "Paste id and secret")
    }

    @Test func anUnknownSlugFallsBackToTheAppName() throws {
        let context = OwnerSetupContext(slug: "acme", appName: "Acme", guide: figmaGuide, usesClient: true, includesAddressStep: false)
        let steps = try #require(OwnerSetupFlow.steps(context))
        let open = try #require(steps.first { $0.id == "app" })
        #expect(open.title == "Open Acme developer page")
        let token = OwnerSetupContext(slug: "acme", appName: "Acme", guide: githubGuide, usesClient: false)
        let tokenSteps = try #require(OwnerSetupFlow.steps(token))
        let paste = try #require(tokenSteps.first { $0.id == "token" })
        #expect(paste.title == "Paste token")
    }

    @Test func googleOpensTheConsoleThenShowsTheAddressToCopy() throws {
        let steps = try #require(OwnerSetupFlow.steps(google()))
        let open = try #require(steps.first { $0.id == "console" })
        #expect(open.kind == .instruction(openPage: link("Open Google Cloud credentials", "https://console.cloud.google.com/apis/credentials")))
        #expect(open.title == "Open Google Cloud")
        #expect(open.body == "Create an OAuth client of type Web application. Pal opens the right page.")
        #expect(open.note == "You need a Google account that can create projects. If Google asks you to create a project first, do that, then come back.")
        #expect(open.skipTarget == "client")
        #expect(open.links.isEmpty)
        let copy = try #require(steps.first { $0.id == "console-copy" })
        #expect(copy.kind == .copyCard(copies: [SetupCopy(label: "Redirect URI", value: "https://pal.example.com/oauth/callback")]))
        #expect(copy.title == "Create the client")
        #expect(copy.heading == "Paste this address into Google")
        #expect(copy.body == "Under Authorized redirect URIs, add:")
    }

    @Test func aLinksOnlyStepKeepsTheGatewayTextAndExtraButtons() throws {
        let steps = try #require(OwnerSetupFlow.steps(google()))
        let apis = try #require(steps.first { $0.id == "apis" })
        #expect(apis.kind == .instruction(openPage: nil))
        #expect(apis.heading == "Turn on the Google services")
        #expect(apis.body == "Turn on each service Pal should use.")
        #expect(apis.title == "Turn on services")
        #expect(apis.primaryTitle == "Next")
        #expect(apis.links.map(\.label) == ["Gmail", "Drive"])
        #expect(apis.skipTarget == nil)
    }

    @Test func aStepWithOnlyCopiesBecomesACopyCard() throws {
        let guide = SetupGuide(steps: [
            SetupStep(id: "name", kind: .openPage, title: "Name it", body: "Use this name.", copies: [SetupCopy(label: "Name", value: "Pal")]),
            githubGuide.steps[1],
        ])
        let context = OwnerSetupContext(slug: "github", appName: "GitHub", guide: guide, usesClient: false)
        let steps = try #require(OwnerSetupFlow.steps(context))
        let name = try #require(steps.first { $0.id == "name" })
        #expect(name.kind == .copyCard(copies: [SetupCopy(label: "Name", value: "Pal")]))
        #expect(name.title == "Name it")
    }

    @Test func githubKeepsThePermissionListFromTheGateway() throws {
        let steps = try #require(OwnerSetupFlow.steps(github))
        let open = try #require(steps.first { $0.id == "token_page" })
        #expect(open.title == "Open GitHub token page")
        #expect(open.body == "Create a fine-grained token. Pal opens the right page.")
        #expect(open.skipTarget == "token")
        #expect(open.note == nil)
        let pick = try #require(steps.first { $0.id == "token_page-copy" })
        #expect(pick.title == "Pick access" && pick.heading == "Pick access")
        #expect(pick.body == "Create a fine-grained token with these permissions.")
        let paste = try #require(steps.first { $0.id == "token" })
        #expect(paste.heading == "Paste your token" && paste.title == "Paste token")
        #expect(paste.fields == githubGuide.steps[1].fields)
    }

    @Test func theSignInStepNamesTheVendor() throws {
        let steps = try #require(OwnerSetupFlow.steps(google()))
        let signIn = try #require(steps.first { $0.id == "signin" })
        #expect(signIn.heading == "Sign in to Google" && signIn.title == "Sign in" && signIn.primaryTitle == "Sign in with Google")
        #expect(signIn.kind == .browserRoundTrip(
            waitingTitle: "Waiting for Google",
            waitingBody: "Finish in the browser. You can close this window; Pal keeps going and tells you when it is done."
        ))
    }

    @Test func theCallbackStepAcceptsAnAddressOnly() throws {
        let steps = try #require(OwnerSetupFlow.steps(google(pasteRoute: true)))
        let callback = try #require(steps.first { $0.id == "callback" })
        #expect(callback.title == "Paste the address")
        #expect(callback.heading == "Paste the address your browser ended on")
        let field = try #require(callback.fields.first)
        #expect(field.id == "callback" && field.prefixes == ["http://", "https://"])
        #expect(field.shape(of: "code=abc") == .wrongStart(["http://", "https://"]))
        #expect(field.shape(of: "http://localhost:1/cb?code=abc") == .valid)
    }

    @Test func theAddressStepIsAnHTTPSPasteWithTheGatewayText() throws {
        let steps = try #require(OwnerSetupFlow.steps(google()))
        let address = try #require(steps.first { $0.id == "address" })
        #expect(address.title == "Your Pal's web address")
        #expect(address.body == "Google sends you back to your Pal.")
        #expect(address.fields == [SetupField(id: "address", label: "Web address", prefixes: ["https://"])])
        #expect(address.fields[0].shape(of: "http://pal.example.com") == .wrongStart(["https://"]))
    }

    @Test(arguments: [
        (SetupProblem.notHTTPS, "Google sends you back to your Pal. The saved address must start with https."),
        (SetupProblem.ipHost, "Google sends you back to your Pal. The saved address is an IP address; use a domain name."),
    ])
    func aSavedAddressThatGoogleWouldRefuseIsExplainedInOneSentence(problem: SetupProblem, body: String) throws {
        var bad = addressStep
        bad.problem = problem
        var guide = googleGuide
        guide.steps[0] = bad
        let context = OwnerSetupContext(slug: "google-workspace", appName: "Google Workspace", guide: guide, usesClient: true, includesAddressStep: true)
        let steps = try #require(OwnerSetupFlow.steps(context))
        let address = try #require(steps.first { $0.id == "address" })
        #expect(address.body == body)
    }

    @Test func discordShapedGuidesAreNotSupported() {
        #expect(!OwnerSetupFlow.supports(discordGuide))
        let context = OwnerSetupContext(slug: "discord", appName: "Discord", guide: discordGuide, usesClient: false)
        #expect(OwnerSetupFlow.steps(context) == nil)
        #expect(OwnerSetupFlow.resume(context, gatewayProgress: SetupProgress(stepID: "token")) == nil)
        #expect(OwnerSetupFlow.supports(googleGuide) && OwnerSetupFlow.supports(githubGuide) && OwnerSetupFlow.supports(figmaGuide))
    }

    @Test func aGuideWithNothingToPasteIsNotSupported() {
        let guide = SetupGuide(steps: [SetupStep(id: "open", kind: .openPage, title: "Open")])
        #expect(!OwnerSetupFlow.supports(guide))
    }

    @Test func aGatewayStepThatReusesAFlowIdIsRefusedInsteadOfBuildingABrokenFlow() {
        let guide = SetupGuide(steps: [
            SetupStep(id: "signin", kind: .openPage, title: "Open", links: [link("Open", "https://example.com")]),
            githubGuide.steps[1],
        ])
        let context = OwnerSetupContext(slug: "acme", appName: "Acme", guide: guide, usesClient: true)
        #expect(OwnerSetupFlow.steps(context) == nil)
    }

    struct AddressCase: Sendable {
        let withStep: Bool
        let redirect: String?
        let hasProblem: Bool
        let expected: Bool
    }

    @Test(arguments: [
        AddressCase(withStep: false, redirect: nil, hasProblem: false, expected: false),
        AddressCase(withStep: true, redirect: nil, hasProblem: false, expected: true),
        AddressCase(withStep: true, redirect: "https://pal.example.com/cb", hasProblem: false, expected: false),
        AddressCase(withStep: true, redirect: "https://pal.example.com/cb", hasProblem: true, expected: true),
    ])
    func theAddressStepIsOfferedOnlyWhenThereIsNoUsableAddress(_ test: AddressCase) {
        var steps = [githubGuide.steps[1]]
        if test.withStep {
            var step = addressStep
            if test.hasProblem { step.problem = .notHTTPS }
            steps.insert(step, at: 0)
        }
        #expect(OwnerSetupFlow.needsAddressStep(guide: SetupGuide(steps: steps), redirectURL: test.redirect) == test.expected)
    }

    @Test(arguments: [google(), google(address: false), google(pasteRoute: true), github, figma])
    func everyFlowIsAValidEngineWithUniqueIdsAnIntroFirstAndSuccessLast(context: OwnerSetupContext) throws {
        let steps = try #require(OwnerSetupFlow.steps(context))
        #expect(Set(steps.map(\.id)).count == steps.count)
        #expect(steps.first?.isIntro == true)
        #expect(steps.last?.isSuccess == true)
        #expect(steps.dropFirst().allSatisfy { !$0.isIntro })
        let known = Set(steps.map(\.id))
        for step in steps { if let target = step.skipTarget { #expect(known.contains(target)) } }
        let engine = try #require(StepFlowEngine(flowID: OwnerSetupFlow.flowID(slug: context.slug), steps: steps))
        #expect(engine.stepCount == steps.filter(\.isChecklistRow).count)
        #expect(engine.checklist.allSatisfy { !$0.title.isEmpty })
    }

    @Test func theEngineStartsOnTheIntroAsStepOneAndNeverGoesBackToIt() throws {
        let steps = try #require(OwnerSetupFlow.steps(github))
        var engine = try #require(StepFlowEngine(flowID: OwnerSetupFlow.flowID(slug: "github"), steps: steps))
        #expect(engine.current.id == "intro")
        #expect(engine.stepNumber == 1 && engine.stepCount == 3)
        #expect(engine.positionLabel == "Step 1 of 3")
        #expect(engine.checklist.map(\.state) == [.current, .upcoming, .upcoming])
        #expect(engine.primaryAction == .advance && engine.isPrimaryEnabled)
        let started = engine.advance()
        #expect(started)
        #expect(engine.current.id == "token_page")
        #expect(engine.stepNumber == 1)
        #expect(!engine.canGoBack)
        let next = engine.advance()
        #expect(next)
        #expect(engine.checklist.map(\.title) == ["Open GitHub token page", "Pick access", "Paste token"])
        #expect(engine.canGoBack)
        let back = engine.back()
        #expect(back)
        #expect(engine.current.id == "token_page")
    }

    @Test func theFlowIdIsPerConnector() {
        #expect(OwnerSetupFlow.flowID(slug: "google-workspace") == "owner-setup-google-workspace")
    }
}

@Suite("Owner setup resume")
struct OwnerSetupResumeTests {
    @Test func aSavedClientResumesAtSignIn() {
        let progress = OwnerSetupFlow.resume(google(configured: true), gatewayProgress: SetupProgress(stepID: "client", saved: ["client_id", "client_secret"]))
        #expect(progress == StepFlowProgress(flowID: "owner-setup-google-workspace", stepID: "signin", saved: ["client_id", "client_secret"]))
        #expect(OwnerSetupFlow.resume(google(configured: true), gatewayProgress: nil)?.stepID == "signin")
    }

    @Test func aConfiguredTokenConnectorResumesAtTheTokenStep() {
        let context = OwnerSetupContext(slug: "github", appName: "GitHub", guide: githubGuide, usesClient: false, configured: true)
        #expect(OwnerSetupFlow.resume(context, gatewayProgress: nil)?.stepID == "token")
    }

    @Test func gatewayProgressMapsOntoTheFlowStepWithTheSameId() {
        let progress = OwnerSetupFlow.resume(google(), gatewayProgress: SetupProgress(stepID: "apis", saved: ["client_id", "ghost"]))
        #expect(progress == StepFlowProgress(flowID: "owner-setup-google-workspace", stepID: "apis", saved: ["client_id"]))
        #expect(OwnerSetupFlow.resume(google(), gatewayProgress: SetupProgress(stepID: "client"))?.stepID == "client")
    }

    @Test func aFreshGuideStartsAtTheIntro() {
        #expect(OwnerSetupFlow.resume(google(), gatewayProgress: SetupProgress(stepID: "address")) == nil)
        #expect(OwnerSetupFlow.resume(google(address: false), gatewayProgress: SetupProgress(stepID: "console")) == nil)
        #expect(OwnerSetupFlow.resume(github, gatewayProgress: SetupProgress(stepID: "token_page")) == nil)
        #expect(OwnerSetupFlow.resume(github, gatewayProgress: nil) == nil)
    }

    @Test func aLaterGatewayStepSurvivesWhenTheAddressStepIsLeftOut() {
        #expect(OwnerSetupFlow.resume(google(address: false), gatewayProgress: SetupProgress(stepID: "address", saved: ["client_id"]))?.stepID == "console")
        #expect(OwnerSetupFlow.resume(google(), gatewayProgress: SetupProgress(stepID: "console"))?.stepID == "console")
    }

    @Test func anUnknownGatewayStepStartsAtTheIntro() {
        #expect(OwnerSetupFlow.resume(google(), gatewayProgress: SetupProgress(stepID: "mystery")) == nil)
    }

    @Test func theResumedProgressIsAcceptedByTheEngine() throws {
        let context = google()
        let steps = try #require(OwnerSetupFlow.steps(context))
        let progress = try #require(OwnerSetupFlow.resume(context, gatewayProgress: SetupProgress(stepID: "client", saved: ["client_id"])))
        let engine = try #require(StepFlowEngine(flowID: progress.flowID, steps: steps, resume: progress))
        #expect(engine.current.id == "client")
        #expect(engine.progress.saved == ["client_id"])
        let signedIn = try #require(OwnerSetupFlow.resume(google(configured: true), gatewayProgress: nil))
        #expect(StepFlowEngine(flowID: signedIn.flowID, steps: steps, resume: signedIn)?.current.id == "signin")
    }
}
