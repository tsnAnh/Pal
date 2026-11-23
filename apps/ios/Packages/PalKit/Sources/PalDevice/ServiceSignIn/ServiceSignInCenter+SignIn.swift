import PalProtocol

extension ServiceSignInCenter {
    public func signIn(for service: String? = nil) async {
        guard let dialog = service.map(dialog(for:)) ?? current, dialog.phase == .prompting, dialog.canSignIn else { return }
        if dialog.requiresAppSignIn {
            if dialog.automaticSignInAvailable {
                await signInNatively(service: dialog.service, requestID: dialog.requestID)
            } else {
                await startPasting(service: dialog.service, requestID: dialog.requestID)
            }
            return
        }
        switch dialog.flow {
        case .deviceCode, .oauthPaste: await openVerificationPage(for: dialog)
        case .oauth: await openAuthorizationPage(for: dialog)
        case .apiKey, .header, .manual, .unknown: return
        }
    }

    private func openVerificationPage(for dialog: ServiceSignInDialog) async {
        let service = dialog.service
        guard let url = Self.secureURL(dialog.verificationURI) else {
            setPhase(.failed(Self.pageFailure), for: service)
            return
        }
        setPhase(.signingIn, for: service)
        openBrowser(url)
        do {
            _ = try await call(ServiceSignInWire.signInMethod, ServiceSignInWire.requestParams(dialog.requestID))
        } catch {
            setPhase(.failed(Self.startFailure), for: service, ifRequest: dialog.requestID)
        }
    }

    private func openAuthorizationPage(for dialog: ServiceSignInDialog) async {
        let service = dialog.service
        let requestID = dialog.requestID
        setPhase(.signingIn, for: service)
        do {
            let result = AuthSignInResult(try await call(ServiceSignInWire.signInMethod, ServiceSignInWire.requestParams(requestID)))
            guard result.recorded, let url = Self.secureURL(result.authorizationURL) else {
                setPhase(.failed(Self.startFailure), for: service, ifRequest: requestID)
                return
            }
            guard isWaiting(service, requestID) else { return }
            openBrowser(url)
        } catch {
            setPhase(.failed(Self.startFailure), for: service, ifRequest: requestID)
        }
    }
}
