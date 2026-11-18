import Foundation

public struct OwnerSetupContext: Sendable, Equatable {
    public var slug: String
    public var appName: String
    public var guide: SetupGuide
    public var usesClient: Bool
    public var redirectURL: String?
    public var includesAddressStep: Bool
    public var configured: Bool
    public var pasteRoute: Bool

    public init(
        slug: String, appName: String, guide: SetupGuide, usesClient: Bool, redirectURL: String? = nil,
        includesAddressStep: Bool = false, configured: Bool = false, pasteRoute: Bool = false
    ) {
        self.slug = slug
        self.appName = appName
        self.guide = guide
        self.usesClient = usesClient
        self.redirectURL = redirectURL
        self.includesAddressStep = includesAddressStep
        self.configured = configured
        self.pasteRoute = pasteRoute
    }
}

public enum OwnerSetupFlow {
    public enum StepID {
        public static let intro = "intro"
        public static let address = "address"
        public static let signIn = "signin"
        public static let callback = "callback"
        public static let done = "done"

        public static func copy(of stepID: String) -> String { stepID + "-copy" }
    }

    private static let supportedKinds: Set<SetupStep.Kind> = [.publicURL, .openPage, .paste]

    public static func flowID(slug: String) -> String { "owner-setup-\(slug)" }

    public static func supports(_ guide: SetupGuide) -> Bool {
        guide.steps.allSatisfy { supportedKinds.contains($0.kind) } && guide.steps.contains { $0.kind == .paste }
    }

    public static func needsAddressStep(guide: SetupGuide, redirectURL: String?) -> Bool {
        guide.needsPublicAddress && (redirectURL == nil || guide.addressStep?.problem != nil)
    }

    public static func steps(_ context: OwnerSetupContext) -> [FlowStep]? {
        guard supports(context.guide) else { return nil }
        let text = Wording(context)
        var body: [FlowStep] = []
        for (offset, step) in context.guide.steps.enumerated() {
            switch step.kind {
            case .publicURL:
                if context.includesAddressStep { body.append(addressStep(step)) }
            case .openPage:
                let skipTarget = context.guide.steps[(offset + 1)...].first { $0.kind == .paste }?.id
                body.append(contentsOf: pageSteps(step, skipTarget: skipTarget, text: text))
            case .paste:
                body.append(pasteStep(step, text: text, usesClient: context.usesClient))
            case .serverPicker, .access:
                return nil
            }
        }
        if context.usesClient {
            body.append(signInStep(vendor: text.vendor))
            if context.pasteRoute { body.append(callbackStep()) }
        }
        body.append(
            FlowStep(
                id: StepID.done, title: String(localized: "\(context.appName) is connected"),
                kind: .success(
                    title: String(localized: "\(context.appName) is connected"),
                    body: String(localized: "Pal can use \(context.appName) when you ask. You will not be asked for this again.")
                )
            )
        )
        let all = [introStep(context, text: text, rows: body.filter(\.isChecklistRow).count)] + body
        return Set(all.map(\.id)).count == all.count ? all : nil
    }

    public static func resume(_ context: OwnerSetupContext, gatewayProgress: SetupProgress?) -> StepFlowProgress? {
        guard let steps = steps(context) else { return nil }
        let flow = flowID(slug: context.slug)
        let fieldIDs = Set(steps.flatMap(\.fields).map(\.id))
        let saved = Set(gatewayProgress?.saved ?? []).intersection(fieldIDs).sorted()
        if context.configured {
            let pasteID = context.guide.steps.first(where: { $0.kind == .paste })?.id
            let target: String? = context.usesClient ? StepID.signIn : pasteID
            return target.map { StepFlowProgress(flowID: flow, stepID: $0, saved: saved) }
        }
        guard let progress = gatewayProgress, let start = context.guide.steps.firstIndex(where: { $0.id == progress.stepID }) else { return nil }
        let present = Set(steps.map(\.id))
        for step in context.guide.steps[start...] {
            let id = step.kind == .publicURL ? StepID.address : step.id
            guard present.contains(id) else { continue }
            if id == steps[1].id, saved.isEmpty { return nil }
            return StepFlowProgress(flowID: flow, stepID: id, saved: saved)
        }
        return nil
    }

    private static func introStep(_ context: OwnerSetupContext, text: Wording, rows: Int) -> FlowStep {
        FlowStep(
            id: StepID.intro, title: String(localized: "Set up \(context.appName)"),
            body: String(
                localized: "\(text.vendor) needs you to register Pal once. \(rows) short steps, about 5 minutes. Pal remembers where you are, on every device."
            ),
            kind: .intro(youDo: text.youDo, palDoes: text.palDoes), primaryTitle: String(localized: "Start")
        )
    }

    private static func addressStep(_ step: SetupStep) -> FlowStep {
        let sentence = step.problem?.plainReason
        let body = [step.body, sentence].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let field = SetupField(id: StepID.address, label: String(localized: "Web address"), prefixes: ["https://"])
        return FlowStep(id: StepID.address, title: step.title, body: body, kind: .paste(fields: [field]))
    }

    private static func pageSteps(_ step: SetupStep, skipTarget: String?, text: Wording) -> [FlowStep] {
        if let first = step.links.first, !step.copies.isEmpty {
            let open = FlowStep(
                id: step.id, title: text.openTitle, body: text.openBody, kind: .instruction(openPage: first),
                primaryTitle: text.openTitle, skipTitle: String(localized: "I already have one"), skipTarget: skipTarget,
                note: text.note, links: Array(step.links.dropFirst())
            )
            let copy = FlowStep(
                id: StepID.copy(of: step.id), title: text.copyRowTitle, body: text.copyBody ?? step.body,
                kind: .copyCard(copies: step.copies), heading: text.copyTitle ?? step.title
            )
            return [open, copy]
        }
        if !step.links.isEmpty {
            return [
                FlowStep(
                    id: step.id, title: text.linksRowTitle ?? step.title, body: step.body, kind: .instruction(openPage: nil),
                    primaryTitle: String(localized: "Next"), heading: step.title, links: step.links
                )
            ]
        }
        if !step.copies.isEmpty {
            return [FlowStep(id: step.id, title: step.title, body: step.body, kind: .copyCard(copies: step.copies))]
        }
        return [FlowStep(id: step.id, title: step.title, body: step.body, kind: .instruction(openPage: nil))]
    }

    private static func pasteStep(_ step: SetupStep, text: Wording, usesClient: Bool) -> FlowStep {
        FlowStep(
            id: step.id, title: usesClient ? String(localized: "Paste id and secret") : String(localized: "Paste token"),
            body: step.body, kind: .paste(fields: step.fields), heading: text.pasteTitle ?? step.title
        )
    }

    private static func signInStep(vendor: String) -> FlowStep {
        FlowStep(
            id: StepID.signIn, title: String(localized: "Sign in"),
            body: String(localized: "A browser window opens. Choose the account Pal should use, then allow access. You come straight back here."),
            kind: .browserRoundTrip(
                waitingTitle: String(localized: "Waiting for \(vendor)"),
                waitingBody: String(localized: "Finish in the browser. You can close this window; Pal keeps going and tells you when it is done.")
            ),
            primaryTitle: String(localized: "Sign in with \(vendor)"), heading: String(localized: "Sign in to \(vendor)")
        )
    }

    private static func callbackStep() -> FlowStep {
        let field = SetupField(id: StepID.callback, label: String(localized: "Address from your browser"), prefixes: ["http://", "https://"])
        return FlowStep(
            id: StepID.callback, title: String(localized: "Paste the address"),
            body: String(
                localized: "After you allow access, the browser cannot open the last page. Copy that address from the browser bar and paste it here."
            ),
            kind: .paste(fields: [field]), heading: String(localized: "Paste the address your browser ended on")
        )
    }
}

private struct Wording {
    var vendor: String
    var youDo: String
    var palDoes: String
    var openTitle: String
    var openBody: String
    var note: String?
    var copyRowTitle: String
    var copyTitle: String?
    var copyBody: String?
    var pasteTitle: String?
    var linksRowTitle: String?

    init(_ context: OwnerSetupContext) {
        switch context.slug {
        case "google-workspace": self = .google
        case "figma": self = .clientApp(vendor: "Figma", openTitle: String(localized: "Open Figma developer settings"))
        case "dropbox": self = .clientApp(vendor: "Dropbox", openTitle: String(localized: "Open Dropbox App Console"))
        case "canva": self = .clientApp(vendor: "Canva", openTitle: String(localized: "Open Canva developer portal"))
        case "github": self = .github
        default:
            let app = context.appName
            let openTitle = String(localized: "Open \(app) developer page")
            self = context.usesClient ? .clientApp(vendor: app, openTitle: openTitle) : .tokenApp(vendor: app, openTitle: openTitle)
        }
    }

    private init(
        vendor: String, youDo: String, palDoes: String, openTitle: String, openBody: String, note: String? = nil,
        copyRowTitle: String, copyTitle: String? = nil, copyBody: String? = nil, pasteTitle: String? = nil, linksRowTitle: String? = nil
    ) {
        self.vendor = vendor
        self.youDo = youDo
        self.palDoes = palDoes
        self.openTitle = openTitle
        self.openBody = openBody
        self.note = note
        self.copyRowTitle = copyRowTitle
        self.copyTitle = copyTitle
        self.copyBody = copyBody
        self.pasteTitle = pasteTitle
        self.linksRowTitle = linksRowTitle
    }

    private static var google: Wording {
        Wording(
            vendor: "Google", youDo: String(localized: "Create an OAuth client in Google Cloud and paste two values."),
            palDoes: String(localized: "Fills in the address, checks your values, signs you in."),
            openTitle: String(localized: "Open Google Cloud"),
            openBody: String(localized: "Create an OAuth client of type Web application. Pal opens the right page."),
            note: String(
                localized: "You need a Google account that can create projects. If Google asks you to create a project first, do that, then come back."
            ),
            copyRowTitle: String(localized: "Create the client"), copyTitle: String(localized: "Paste this address into Google"),
            copyBody: String(localized: "Under Authorized redirect URIs, add:"),
            pasteTitle: String(localized: "Paste the two values Google shows"), linksRowTitle: String(localized: "Turn on services")
        )
    }

    private static var github: Wording {
        Wording(
            vendor: "GitHub", youDo: String(localized: "Create a token in GitHub and paste it."),
            palDoes: String(localized: "Checks the token and saves it on your Pal."),
            openTitle: String(localized: "Open GitHub token page"),
            openBody: String(localized: "Create a fine-grained token. Pal opens the right page."),
            copyRowTitle: String(localized: "Pick access"), copyTitle: String(localized: "Pick access"),
            pasteTitle: String(localized: "Paste your token")
        )
    }

    private static func clientApp(vendor: String, openTitle: String) -> Wording {
        Wording(
            vendor: vendor, youDo: String(localized: "Create an app in \(vendor) and paste two values."),
            palDoes: String(localized: "Checks your values and signs you in."), openTitle: openTitle,
            openBody: String(localized: "Create an app for Pal. Pal opens the right page."),
            copyRowTitle: String(localized: "Create the app"),
            copyTitle: String(localized: "Create the app and paste the redirect address"),
            pasteTitle: String(localized: "Paste the two values \(vendor) shows")
        )
    }

    private static func tokenApp(vendor: String, openTitle: String) -> Wording {
        Wording(
            vendor: vendor, youDo: String(localized: "Create a token in \(vendor) and paste it."),
            palDoes: String(localized: "Checks the token and saves it on your Pal."), openTitle: openTitle,
            openBody: String(localized: "Create a token for Pal. Pal opens the right page."),
            copyRowTitle: String(localized: "Pick access"), pasteTitle: String(localized: "Paste your token")
        )
    }
}
