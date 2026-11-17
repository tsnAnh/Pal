import Foundation
import PalConnect
import PalDevice
import PalDiagnostics
import PalProtocol
import PalTransport
import Synchronization
import Testing

@Suite("Google Workspace status")
struct GoogleWorkspaceStatusTests {
    @Test func decodesEveryStateOfTheContract() throws {
        let cases: [(String, GoogleWorkspaceStatus.State)] = [
            ("not_configured", .notConfigured), ("needs_sign_in", .needsSignIn), ("signed_in", .signedIn), ("reauth_needed", .reauthNeeded),
        ]
        for (raw, expected) in cases {
            #expect(try googleStatusJSON(raw).decoded(as: GoogleWorkspaceStatus.self).state == expected)
        }
    }

    @Test func readsEmailServicesAndWriteServicesInStableOrder() throws {
        let status = try googleStatusJSON("signed_in", email: " owner@example.com ", services: ["docs", "gmail", "gmail"], write: ["docs"])
            .decoded(as: GoogleWorkspaceStatus.self)
        #expect(status.email == "owner@example.com")
        #expect(status.services == [.gmail, .docs])
        #expect(status.writeServices == [.docs])
    }

    @Test func everyReauthReasonDecodesAndHasPlainText() throws {
        let expected: [(String, GoogleReauthReason)] = [
            ("token_missing", .tokenMissing), ("token_unreadable", .tokenUnreadable), ("revoked", .revoked), ("client_rejected", .clientRejected),
        ]
        for (raw, reason) in expected {
            let status = try googleStatusJSON("reauth_needed", reason: raw).decoded(as: GoogleWorkspaceStatus.self)
            #expect(status.reauthReason == reason)
        }
        for reason in GoogleReauthReason.allCases {
            let text = reason.plainReason
            #expect(!text.isEmpty)
            #expect(!text.contains("_"))
            #expect(!text.contains("token_"))
        }
    }

    @Test func unknownServicesAndReasonsDoNotCrashDecoding() throws {
        let status = try googleStatusJSON("reauth_needed", services: ["gmail", "photos", "keep"], write: ["photos"], reason: "something_new")
            .decoded(as: GoogleWorkspaceStatus.self)
        #expect(status.services == [.gmail])
        #expect(status.writeServices.isEmpty)
        #expect(status.reauthReason == .unknown)
    }

    @Test func anUnknownStateIsAFailureNotACrash() async {
        let rpc = CustomRPC(["google_workspace.status": googleReply(googleStatusJSON("brand_new_state"))])
        await #expect(throws: GoogleWorkspaceError.failed) { try await googleService(rpc).status() }
    }

    @Test func extraKeysNeverReachTheModel() throws {
        let canary = "CANARY-" + UUID().uuidString
        let status = try googleStatusJSON(
            "signed_in", email: "owner@example.com", services: ["gmail"],
            extra: ["client_secret": .string(canary), "access_token": .string(canary), "refresh_token": .string(canary), "path": .string("/home/" + canary)]
        ).decoded(as: GoogleWorkspaceStatus.self)
        let card = GoogleWorkspaceCardState.resolve(status: status, signingIn: false, failure: nil)
        #expect(!googleRendered(status, card).contains(canary))
    }
}

@Suite("Google scope selection")
struct GoogleScopeSelectionTests {
    @Test func readsDefaultToAllSixAndWritesToNone() {
        let selection = GoogleScopeSelection()
        #expect(selection.read == Set(GoogleService.allCases))
        #expect(selection.write.isEmpty)
        #expect(GoogleService.allCases.count == 6)
    }

    @Test func contactsHasNoWriteOptIn() {
        var selection = GoogleScopeSelection()
        #expect(!GoogleService.contacts.hasWriteOptIn)
        #expect(!selection.allowsWrite(.contacts))
        selection.setWrite(.contacts, true)
        #expect(selection.write.isEmpty)
        for service in GoogleService.allCases where service != .contacts { #expect(selection.allowsWrite(service)) }
    }

    @Test func writeNeedsATickedService() {
        var selection = GoogleScopeSelection()
        selection.setRead(.gmail, false)
        selection.setWrite(.gmail, true)
        #expect(selection.write.isEmpty)
        selection.setRead(.gmail, true)
        selection.setWrite(.gmail, true)
        #expect(selection.write == [.gmail])
    }

    @Test func untickingAServiceDropsItsWriteOptIn() {
        var selection = GoogleScopeSelection()
        selection.setWrite(.drive, true)
        selection.setWrite(.docs, true)
        selection.setRead(.drive, false)
        #expect(selection.write == [.docs])
        selection.setRead(.drive, true)
        #expect(!selection.write.contains(.drive))
    }

    @Test func startParamsListServicesInOrder() {
        var selection = GoogleScopeSelection()
        selection.setRead(.calendar, false)
        selection.setWrite(.docs, true)
        selection.setWrite(.gmail, true)
        let params = selection.startParams
        #expect(params["services"] == .array(["gmail", "drive", "contacts", "sheets", "docs"].map { .string($0) }))
        #expect(params["write_services"] == .array(["gmail", "docs"].map { .string($0) }))
        #expect(Set(params.keys) == ["services", "write_services"])
    }
}

@Suite("Google card state")
struct GoogleCardStateTests {
    private func status(_ state: GoogleWorkspaceStatus.State, reason: GoogleReauthReason? = nil) -> GoogleWorkspaceStatus {
        GoogleWorkspaceStatus(state: state, email: "a@b.co", services: [.gmail], writeServices: [.gmail], reauthReason: reason)
    }

    @Test func resolvesEveryState() {
        typealias Card = GoogleWorkspaceCardState
        #expect(Card.resolve(status: status(.notConfigured), signingIn: false, failure: nil) == .notConfigured)
        #expect(Card.resolve(status: status(.needsSignIn), signingIn: false, failure: nil) == .notSignedIn)
        #expect(Card.resolve(status: nil, signingIn: false, failure: nil) == .notSignedIn)
        #expect(Card.resolve(status: status(.signedIn), signingIn: false, failure: nil) == .signedIn(email: "a@b.co", services: [.gmail], writeServices: [.gmail]))
        #expect(Card.resolve(status: status(.reauthNeeded, reason: .revoked), signingIn: false, failure: nil) == .needsReauth(.revoked))
        #expect(Card.resolve(status: status(.reauthNeeded), signingIn: false, failure: nil) == .needsReauth(.unknown))
        #expect(Card.resolve(status: status(.signedIn), signingIn: true, failure: nil) == .signingIn)
        #expect(Card.resolve(status: status(.signedIn), signingIn: false, failure: "Nope.") == .failed("Nope."))
        #expect(Card.resolve(status: status(.signedIn), signingIn: false, failure: "  ") == .signedIn(email: "a@b.co", services: [.gmail], writeServices: [.gmail]))
    }

    @Test func everyTextIsPlainLanguage() {
        var texts = GoogleReauthReason.allCases.map(\.plainReason)
        texts += [GoogleWorkspaceCardState.notConfigured, .notSignedIn, .signingIn, .signedIn(email: nil, services: [], writeServices: [])].map(\.summary)
        let errors: [GoogleWorkspaceError] = [.ownerOnly, .notConfigured, .invalidClient, .notDesktopClient, .invalidServices, .unreachable, .signInEnded, .failed]
        texts += errors.map(\.reason)
        for text in texts {
            #expect(!text.isEmpty)
            for banned in ["4101", "4403", "5321", "google_workspace", "RPC", "token_", "invalid_", "not_desktop"] { #expect(!text.contains(banned)) }
        }
        #expect(GoogleWorkspaceCardState.signedIn(email: "a@b.co", services: [], writeServices: []).summary == "Signed in as a@b.co")
    }
}

@Suite("Google Workspace service")
struct GoogleWorkspaceServiceTests {
    @Test func statusAndVerifyAreHostLevelWithNoProfile() async throws {
        let rpc = CustomRPC([
            "google_workspace.status": googleReply(googleSignedInStatus),
            "google_workspace.verify": googleReply(googleStatusJSON("needs_sign_in")),
        ])
        let status = try await googleService(rpc).status()
        #expect(status.state == .signedIn)
        #expect(try await googleService(rpc).verify().state == .needsSignIn)
        #expect(rpc.params("google_workspace.status") == [.object([:])])
        #expect(rpc.params("google_workspace.verify") == [.object([:])])
    }

    @Test func mapsGatewayErrorsToTypedFailures() async {
        let cases: [(Int, String?, GoogleWorkspaceError)] = [
            (4403, nil, .ownerOnly), (4101, "invalid_client", .invalidClient), (4101, "not_desktop_client", .notDesktopClient),
            (4101, "invalid_services", .invalidServices), (4101, "not_configured", .notConfigured), (4101, "other", .failed),
            (5321, "unreachable", .unreachable), (5321, "failed", .failed), (-32601, nil, .failed),
        ]
        for (code, dataCode, expected) in cases {
            let rpc = CustomRPC(["google_workspace.status": gatewayError(code, dataCode)])
            await #expect(throws: expected) { try await googleService(rpc).status() }
        }
    }

    @Test func aDroppedConnectionIsAPlainFailure() async {
        let rpc = CustomRPC(["google_workspace.verify": { _ in throw GatewayTransportError.timedOut }])
        await #expect(throws: GoogleWorkspaceError.failed) { try await googleService(rpc).verify() }
    }

    @Test func setClientSendsBothValuesOnce() async throws {
        let rpc = CustomRPC(["google_workspace.client.set": googleReply(googleStatusJSON("needs_sign_in"))])
        let status = try await googleService(rpc).setClient(clientID: SecretString("id-1"), clientSecret: SecretString("secret-1"))
        #expect(status.state == .needsSignIn)
        #expect(rpc.methods() == ["google_workspace.client.set"])
        #expect(rpc.params("google_workspace.client.set") == [.object(["client_id": "id-1", "client_secret": "secret-1"])])
    }

    @Test func setClientRefusesAnEmptyValueWithoutCalling() async {
        let rpc = CustomRPC([:])
        await #expect(throws: GoogleWorkspaceError.invalidClient) {
            try await googleService(rpc).setClient(clientID: SecretString(""), clientSecret: SecretString("secret"))
        }
        await #expect(throws: GoogleWorkspaceError.invalidClient) {
            try await googleService(rpc).setClient(clientID: SecretString("id"), clientSecret: SecretString(""))
        }
        #expect(rpc.methods().isEmpty)
    }

    @Test func aRejectedClientIsReportedPlainly() async {
        let rpc = CustomRPC(["google_workspace.client.set": gatewayError(4101, "not_desktop_client")])
        await #expect(throws: GoogleWorkspaceError.notDesktopClient) {
            try await googleService(rpc).setClient(clientID: SecretString("id"), clientSecret: SecretString("secret"))
        }
    }

    @Test func signOutRemovesOnlyTheTokenByDefault() async throws {
        let rpc = CustomRPC(["google_workspace.signout": googleReply(googleStatusJSON("needs_sign_in"))])
        _ = try await googleService(rpc).signOut()
        #expect(rpc.methods() == ["google_workspace.signout"])
        #expect(rpc.params("google_workspace.signout") == [.object(["remove_setup": .bool(false)])])
    }

    @Test func removeSetupIsExplicit() async throws {
        let rpc = CustomRPC(["google_workspace.signout": googleReply(googleStatusJSON("not_configured"))])
        let status = try await googleService(rpc).signOut(removeSetup: true)
        #expect(status.state == .notConfigured)
        #expect(rpc.params("google_workspace.signout") == [.object(["remove_setup": .bool(true)])])
    }
}
