import Foundation
import PalProtocol

public enum GoogleAdsFlow {
    public static let flowID = "google-ads"

    public enum StepID {
        public static let api = "api"
        public static let explorer = "explorer"
        public static let consent = "consent"
        public static let signIn = "signin"
        public static let manager = "manager"
        public static let check = "check"
        public static let done = "done"
    }

    public static let adwordsScope = "https://www.googleapis.com/auth/adwords"
    public static let testingModeSentence = String(localized: "While the app is in Testing mode, Google ends the sign-in after 7 days.")
    public static let laterOption = String(
        localized: """
            Later you can publish the app in Google Cloud to remove that limit. \
            Google Ads is a sensitive permission, so Google may ask to verify the app first.
            """
    )

    public static let apiLink = SetupLink(
        label: String(localized: "Open Google Cloud"), url: URL(string: "https://console.cloud.google.com/apis/library/googleads.googleapis.com")!
    )
    public static let explorerLink = SetupLink(
        label: String(localized: "Open Google Cloud"), url: URL(string: "https://console.cloud.google.com/apis/api/googleads.googleapis.com/overview")!
    )
    public static let consentLink = SetupLink(
        label: String(localized: "Open the consent screen"), url: URL(string: "https://console.cloud.google.com/apis/credentials/consent")!
    )

    public static let managerField = SetupField(id: "manager", label: String(localized: "Manager account ID (optional)"))

    public static func steps() -> [FlowStep] {
        guideSteps() + accessSteps()
    }

    private static func guideSteps() -> [FlowStep] {
        [
            FlowStep(
                id: StepID.api, title: String(localized: "Enable the Google Ads API"),
                body: String(
                    localized: "In the Google Cloud project you use for Google Workspace, turn on the Google Ads API. Pal opens the page for you."
                ),
                kind: .instruction(openPage: apiLink), heading: String(localized: "Turn on the Google Ads API")
            ),
            FlowStep(
                id: StepID.explorer, title: String(localized: "Apply for Explorer access"),
                body: String(
                    localized: """
                        Google approves each Cloud project before it can read Google Ads. \
                        Open the Google Ads API page and apply for Explorer access. The review is automatic and takes minutes.
                        """
                ),
                kind: .instruction(openPage: explorerLink)
            ),
            FlowStep(
                id: StepID.consent, title: String(localized: "Allow Google Ads sign-in"),
                body: String(
                    localized: """
                        Pal reuses the Google sign-in you saved for Google Workspace. \
                        On its consent screen, add the Google Ads permission `\(adwordsScope)` and add your Google account as a test user. \
                        \(testingModeSentence)
                        """
                ),
                kind: .instruction(openPage: consentLink), heading: String(localized: "Add Google Ads to your Google sign-in"),
                note: laterOption
            ),
        ]
    }

    private static func accessSteps() -> [FlowStep] {
        [
            FlowStep(
                id: StepID.signIn, title: String(localized: "Sign in"),
                body: String(
                    localized: "A browser window opens. Choose the Google account that manages your ads, then allow access. You come straight back here."
                ),
                kind: .browserRoundTrip(
                    waitingTitle: String(localized: "Waiting for Google"),
                    waitingBody: String(localized: "Finish in the browser. You can close this window; Pal keeps going and tells you when it is done.")
                ),
                primaryTitle: String(localized: "Sign in with Google"), heading: String(localized: "Sign in to Google")
            ),
            FlowStep(
                id: StepID.manager, title: String(localized: "Manager account"),
                body: String(
                    localized: """
                        If you use a Google Ads manager account, enter its ID so Pal reads through it. \
                        The accounts Pal can read come from the Google account you signed in with, so there is nothing else to add. \
                        If you do not use one, skip this step.
                        """
                ),
                kind: .paste(fields: [managerField]), primaryTitle: String(localized: "Save"),
                skipTitle: String(localized: "Skip"), skipTarget: StepID.check, heading: String(localized: "Add your manager account"),
                inlineRefusal: true
            ),
            FlowStep(
                id: StepID.check, title: String(localized: "Check access"),
                body: String(localized: "Pal saves a read-only Google Ads connection and checks it with your Google account."),
                kind: .action(
                    waitingTitle: String(localized: "Checking Google Ads"),
                    waitingBody: String(localized: "This takes a moment. You can leave this open.")
                ),
                primaryTitle: String(localized: "Check access"), heading: String(localized: "Check your Google Ads access"),
                showsInChecklist: false
            ),
            FlowStep(
                id: StepID.done, title: String(localized: "Google Ads is connected"),
                kind: .success(
                    title: String(localized: "Google Ads is connected"),
                    body: String(localized: "Pal can read your campaign stats and never changes a campaign. You can change this any time from Connect Apps.")
                )
            ),
        ]
    }

    public static func startStep(for status: GoogleAdsStatus?) -> String {
        switch status?.state {
        case .needsReconnect: StepID.signIn
        case .signedIn: status?.configured == true ? StepID.check : StepID.manager
        case .needsSetup, .needsSignIn, nil: StepID.api
        }
    }

    public static func engine(status: GoogleAdsStatus?) -> StepFlowEngine? {
        StepFlowEngine(flowID: flowID, steps: steps(), resume: StepFlowProgress(flowID: flowID, stepID: startStep(for: status)))
    }

    public static func status(for check: GoogleAdsCheck) -> SetupStatus? {
        let method = "connectors.google_ads.verify"
        switch check {
        case .ready:
            return nil
        case .explorerAccessNeeded:
            return SetupStatus(code: SetupStatusClass.explorerAccessNeeded.rawValue, method: method, subject: GoogleAdsConnector.name)
        case .needsReauth:
            return needsSignIn(method: method)
        case .unreachable:
            return custom(
                code: "unreachable", method: method, title: String(localized: "Pal could not reach Google Ads"),
                reason: String(localized: "Google did not answer. Try again in a moment."), action: String(localized: "Try again")
            )
        }
    }

    static func needsSignIn(method: String?) -> SetupStatus {
        SetupStatus(code: SetupStatusClass.needsReauth.rawValue, method: method, subject: GoogleAdsConnector.name)
    }

    static let invalidManagerID = custom(
        code: SetupStatusClass.vendorRefusedValue.rawValue, method: nil,
        title: String(localized: "That manager account ID does not look right"),
        reason: String(localized: "Use only the digits of the ID, for example 1234567890. Dashes are fine, letters are not."),
        action: String(localized: "Edit manager account ID")
    )

    static let needsSetup = custom(
        code: "needs_setup", method: nil, title: String(localized: "Set up Google Workspace first"),
        reason: String(
            localized: "Google Ads signs in with the Google sign-in you saved for Google Workspace. Connect Google Workspace first, then come back."
        ),
        action: String(localized: "Try again")
    )

    static func custom(code: String, method: String?, title: String, reason: String, action: String, fault: GatewayFault? = nil) -> SetupStatus {
        var status = SetupStatus(
            code: code, method: fault?.method ?? method, trace: fault?.trace.rawValue, gatewayVersion: fault?.gatewayVersion,
            subject: GoogleAdsConnector.name
        )
        status.title = title
        status.reason = reason
        status.actionTitle = action
        return status
    }

    @MainActor
    public static func recover(_ failure: SetupStatus, in model: StepFlowModel) async {
        switch failure.kind {
        case .explorerAccessNeeded:
            model.openPage(explorerLink.url)
            model.dismissFailure()
        case .needsReauth:
            model.dismissFailure()
            while model.engine.current.id != StepID.signIn {
                let before = model.engine.index
                await model.back()
                if model.engine.index >= before { break }
            }
        case .vendorRefusedValue:
            model.dismissFailure()
        default:
            await model.retryAfterFailure()
        }
    }
}

public struct GoogleAdsFlowRunner: Sendable {
    private let service: ConnectAppsService

    public init(service: ConnectAppsService) {
        self.service = service
    }

    public func run(_ step: FlowStep, values: [String: String]) async throws {
        switch step.id {
        case GoogleAdsFlow.StepID.signIn: try await service.signInGoogleAds()
        case GoogleAdsFlow.StepID.manager: try await saveManager(values[GoogleAdsFlow.managerField.id] ?? "")
        case GoogleAdsFlow.StepID.check: try await checkAccess()
        default: break
        }
    }

    public func classify(_ error: any Error) -> SetupStatus {
        switch error {
        case let carried as SetupStatusError:
            return carried.status
        case ConnectAppsError.signInFailed(let reason):
            return SetupStatus(
                code: SetupStatusClass.signInIncomplete.rawValue, method: "connectors.oauth_client.connect", subject: GoogleAdsConnector.name,
                detail: reason
            )
        case ConnectAppsError.oauthClient(let failure, let fault):
            return Self.status(for: failure, fault: fault)
        default:
            return SetupStatus(error: error, subject: GoogleAdsConnector.name)
        }
    }

    private func saveManager(_ raw: String) async throws {
        switch ManagerAccountID.parse(raw) {
        case .invalid: throw SetupStatusError(GoogleAdsFlow.invalidManagerID)
        case .skip: return
        case .id(let digits): try await service.saveGoogleAds(loginCustomerID: digits)
        }
    }

    private func checkAccess() async throws {
        let current = try await service.googleAdsStatus()
        switch current.state {
        case .needsSetup: throw SetupStatusError(GoogleAdsFlow.needsSetup)
        case .needsSignIn, .needsReconnect: throw SetupStatusError(GoogleAdsFlow.needsSignIn(method: "connectors.google_ads.status"))
        case .signedIn: break
        }
        if !current.configured { try await service.saveGoogleAds(loginCustomerID: nil) }
        let result = try await service.verifyGoogleAds()
        if let status = GoogleAdsFlow.status(for: result.check) { throw SetupStatusError(status) }
    }

    private static func status(for failure: OAuthClientFailure, fault: GatewayFault?) -> SetupStatus {
        let method = fault?.method
        switch failure {
        case .notOwner:
            return SetupStatus(
                code: SetupStatusClass.forbidden.rawValue, method: method, trace: fault?.trace.rawValue,
                gatewayVersion: fault?.gatewayVersion, subject: GoogleAdsConnector.name
            )
        case .unreachable:
            return SetupStatus(code: SetupStatusClass.offline.rawValue, method: method, subject: GoogleAdsConnector.name)
        case .needsSetup:
            return GoogleAdsFlow.custom(
                code: "needs_setup", method: method, title: GoogleAdsFlow.needsSetup.title, reason: GoogleAdsFlow.needsSetup.reason,
                action: GoogleAdsFlow.needsSetup.actionTitle, fault: fault
            )
        case .needsPublicURL:
            return GoogleAdsFlow.custom(
                code: "needs_public_url", method: method, title: String(localized: "Your Pal needs a web address"),
                reason: String(localized: "Google sends you back to your Pal after you sign in. Set your Pal's web address first, then try again."),
                action: String(localized: "Try again"), fault: fault
            )
        case .connectFailed where fault?.code == 4000:
            return GoogleAdsFlow.custom(
                code: SetupStatusClass.vendorRefusedValue.rawValue, method: method, title: GoogleAdsFlow.invalidManagerID.title,
                reason: GoogleAdsFlow.invalidManagerID.reason, action: GoogleAdsFlow.invalidManagerID.actionTitle, fault: fault
            )
        case .connectFailed where method == "connectors.oauth_client.connect":
            return GoogleAdsFlow.custom(
                code: "connect_failed", method: method, title: String(localized: "Sign-in did not start"),
                reason: String(localized: "Pal could not open the Google sign-in. Try again."), action: String(localized: "Try again"), fault: fault
            )
        case .connectFailed:
            return GoogleAdsFlow.custom(
                code: "connect_failed", method: method, title: String(localized: "Pal could not start Google Ads"),
                reason: String(localized: "Your sign-in is saved, but the read-only Google Ads connection did not start. Try again in a moment."),
                action: String(localized: "Try again"), fault: fault
            )
        case .invalidClient, .clientUnreadable, .saveFailed:
            return SetupStatus(
                code: SetupStatusClass.internalFault.rawValue, method: method, trace: fault?.trace.rawValue,
                gatewayVersion: fault?.gatewayVersion, subject: GoogleAdsConnector.name
            )
        }
    }
}
