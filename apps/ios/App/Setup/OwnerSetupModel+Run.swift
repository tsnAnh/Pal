import Foundation
import PalConnect
import PalDesign

extension OwnerSetupModel {
    func run(_ step: FlowStep, _ values: [String: String]) async throws {
        guard let context else { throw ConnectAppsError.failed }
        switch step.id {
        case OwnerSetupFlow.StepID.address: try await saveAddress(values, context)
        case OwnerSetupFlow.StepID.signIn: try await signIn(context)
        case OwnerSetupFlow.StepID.callback: try await submitCallback(values)
        default: try await checkValues(step, values, context)
        }
    }

    private func saveAddress(_ values: [String: String], _ context: OwnerSetupContext) async throws {
        switch PublicAddress.evaluate(values[OwnerSetupFlow.StepID.address] ?? "") {
        case .address(let url): _ = try await service.savePublicAddress(url)
        case .refused(let problem): throw PublicAddressError(.refused(problem))
        case .clear: throw PublicAddressError(.refused(.invalid))
        }
        let setup = try await service.oauthClientSetup(slug: context.slug)
        var next = context
        next.redirectURL = setup.redirectURL
        if let guide = try await service.catalogEntry(slug: context.slug)?.setupGuide { next.guide = guide }
        try apply(next)
    }

    private func checkValues(_ step: FlowStep, _ values: [String: String], _ context: OwnerSetupContext) async throws {
        guard let guideStep = context.guide.steps.first(where: { $0.id == step.id && $0.kind == .paste }) else {
            throw ConnectAppsError.failed
        }
        let sent = values.compactMapValues { SecretEntryInput.trimmed($0) }
        let verification = try await service.verifySetup(entry, step: guideStep, values: sent)
        guard verification.result.ok else { throw OwnerSetupError.check(verification.result.failure(appName: app.name)) }
        if context.usesClient {
            try await service.saveVerifiedClient(entry, verification)
            setConfigured(true)
            return
        }
        await service.discardVerified(verification)
        try await service.connect(app, credentials: ["token": sent["token"] ?? ""])
        guard let failure = await service.tokenFailure(app) else { return }
        if failure == .authRefused { throw OwnerSetupError.tokenRefused }
        throw ConnectAppsError.failed
    }

    private func signIn(_ context: OwnerSetupContext) async throws {
        discard()
        if let fresh = try await service.catalogEntry(slug: context.slug) { entry = fresh }
        let route = McpConnectRoute.decide(requires: [], platform: ConnectorPlatform.current)
        let outcome: OAuthClientConnectOutcome
        do {
            outcome = try await service.connectOAuthClient(entry, route: route)
        } catch ConnectAppsError.cancelled {
            throw CancellationError()
        }
        switch outcome {
        case .connected:
            try dropCallbackStep(context)
        case .paste(let session):
            try await openBrowser(for: session, context)
        }
    }

    private func dropCallbackStep(_ context: OwnerSetupContext) throws {
        guard context.pasteRoute else { return }
        var next = context
        next.pasteRoute = false
        try apply(next)
    }

    private func openBrowser(for session: any McpPasteSigning, _ context: OwnerSetupContext) async throws {
        guard context.pasteRoute else {
            await session.cancel()
            throw ConnectAppsError.oauthClient(.connectFailed)
        }
        guard ExternalLink.open(session.authorizeURL) else {
            await session.cancel()
            throw ConnectAppsError.signInFailed(McpOAuthError.browserUnavailable.reason)
        }
        pasteSession = session
    }

    private func submitCallback(_ values: [String: String]) async throws {
        guard let session = pasteSession else { throw ConnectAppsError.signInFailed(McpSignInFailure.expired.reason) }
        switch await session.submit(values[OwnerSetupFlow.StepID.callback] ?? "") {
        case .signedIn:
            pasteSession = nil
        case .tryAgain(let note):
            throw OwnerSetupError.pasteRefused(note)
        case .failed(let reason):
            pasteSession = nil
            throw ConnectAppsError.signInFailed(reason)
        case .adminApprovalPending:
            pasteSession = nil
            throw ConnectAppsError.adminApprovalPending
        }
    }
}
