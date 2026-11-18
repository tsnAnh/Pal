import Foundation
@testable import PalConnect
import PalProtocol
import Testing

private func fault(_ reason: String, method: String = "connectors.oauth_client.save") throws -> GatewayFault {
    GatewayFault(
        code: 4030, reason: reason, trace: try #require(TraceID("gj43o07j")), method: method, source: .gateway, gatewayVersion: "bbf2401c"
    )
}

@Suite("Setup status from connect errors")
struct SetupStatusConnectTests {
    @Test func aRefusedClientIsTheVendorRefusingTheValue() throws {
        let refused = try fault("INVALID_CLIENT")
        let status = SetupStatus(error: ConnectAppsError.oauthClient(.invalidClient, refused), subject: "Google", valueName: "client ID")
        #expect(status.kind == .vendorRefusedValue)
        #expect(status.code == "invalid_client")
        #expect(status.title == "Google did not accept that client ID")
        #expect(status.method == "connectors.oauth_client.save")
        #expect(status.trace == "gj43o07j")
        #expect(status.gatewayVersion == "bbf2401c")
    }

    @Test func notOwnerAndUnreachableKeepTheirClasses() {
        #expect(SetupStatus(error: ConnectAppsError.oauthClient(.notOwner), subject: "Figma").kind == .forbidden)
        let offline = SetupStatus(error: ConnectAppsError.oauthClient(.unreachable), subject: "Figma")
        #expect(offline.kind == .offline && offline.code == "unreachable" && offline.method == nil)
    }

    @Test(arguments: [
        OAuthClientFailure.needsSetup, .needsPublicURL, .clientUnreadable, .saveFailed, .connectFailed,
    ])
    func theOtherClientFailuresAreInternalWithTheirOwnSentenceAndCode(failure: OAuthClientFailure) {
        let status = SetupStatus(error: ConnectAppsError.oauthClient(failure), subject: "Figma")
        #expect(status.kind == .internalFault)
        #expect(status.code == failure.rawValue)
        #expect(status.reason == failure.reason)
    }

    @Test func aFaultedErrorUsesTheFaultsOwnReason() throws {
        let faulted = try fault("forbidden", method: "mcp.servers.add")
        let status = SetupStatus(error: ConnectAppsError.faulted(faulted), subject: "Notion")
        #expect(status.kind == .forbidden)
        #expect(status.method == "mcp.servers.add")
        #expect(status.trace == "gj43o07j")
    }

    @Test func aSignInThatDidNotFinishCarriesItsReason() {
        let status = SetupStatus(error: ConnectAppsError.signInFailed("Google closed the window."), subject: "Google")
        #expect(status.code == "sign_in_failed")
        #expect(status.kind == .internalFault)
        #expect(status.title == "Sign-in did not finish")
        #expect(status.reason == "Google closed the window.")
        #expect(status.actionTitle == "Try again")
    }

    @Test(arguments: [ConnectAppsError.unavailable, .failed, .cancelled, .credentialsRequired(["token"])])
    func theRemainingConnectErrorsAreInternal(error: ConnectAppsError) {
        #expect(SetupStatus(error: error, subject: "Figma").kind == .internalFault)
    }

    @Test func aRefusedAddressNamesTheProblemAndEditsTheAddress() throws {
        let rejected = try fault("invalid", method: "webapp.public_url.set")
        let status = SetupStatus(error: PublicAddressError(.refused(.ipHost), fault: rejected), subject: nil)
        #expect(status.kind == .vendorRefusedValue)
        #expect(status.title == "That address was not accepted")
        #expect(status.reason == PublicAddress.Problem.ipHost.message)
        #expect(status.actionTitle == "Edit address")
        #expect(status.method == "webapp.public_url.set")
    }

    @Test func aManagedAddressCannotBeChangedHere() {
        let status = SetupStatus(error: PublicAddressError(.managed), subject: nil)
        #expect(status.kind == .internalFault)
        #expect(status.code == "managed")
        #expect(status.reason == "This address is managed for you and cannot be changed here.")
        #expect(SetupStatus(error: PublicAddressError(.ownerOnly), subject: nil).kind == .forbidden)
    }

    @Test func anotherAddressFailureFollowsItsFaultOrIsInternal() throws {
        let offline = SetupStatus(error: PublicAddressError(.other, fault: .transport("unreachable", method: "webapp.public_url.get")), subject: nil)
        #expect(offline.kind == .offline && offline.method == "webapp.public_url.get")
        #expect(SetupStatus(error: PublicAddressError(.other), subject: nil).kind == .internalFault)
    }

    @Test func aGatewayFaultAndAnythingElseAreMapped() throws {
        let reauth = SetupStatus(error: try fault("needs_reauth"), subject: "Figma")
        #expect(reauth.kind == .needsReauth)
        let offline = SetupStatus(error: URLError(.notConnectedToInternet), subject: "Figma")
        #expect(offline.kind == .offline && offline.code == "offline")
    }

    @Test(arguments: [("INVALID_TOKEN", "token"), ("INVALID_CLIENT", "client ID and secret")])
    func aVendorRefusalKeepsTheFieldEditable(code: String, valueName: String) {
        let status = SetupStatus.checkFailed(SetupCheckFailure(code: code, reason: "x"), subject: "GitHub", valueName: valueName)
        #expect(status.kind == .vendorRefusedValue)
        #expect(status.title == "GitHub did not accept that \(valueName)")
        #expect(status.method == "connectors.setup.check")
    }

    @Test func anUnavailableCheckAsksToTryAgain() {
        let status = SetupStatus.checkFailed(SetupCheckFailure(code: "CHECK_UNAVAILABLE", reason: "x"), subject: "GitHub", valueName: "token")
        #expect(status.kind == .internalFault)
        #expect(status.title == "Pal could not check with GitHub")
        #expect(status.reason == "Try again in a moment.")
        #expect(status.actionTitle == "Try again")
    }

    @Test func anyOtherCheckFailureShowsTheGatewaysSentence() {
        let failure = SetupCheckFailure(code: "CHECK_FAILED", reason: "Pal couldn't check that. Try again.")
        let status = SetupStatus.checkFailed(failure, subject: "GitHub", valueName: "token")
        #expect(status.kind == .internalFault)
        #expect(status.code == "CHECK_FAILED")
        #expect(status.reason == "Pal couldn't check that. Try again.")
    }

    @Test func aReachableAddressIsNotAFailure() {
        #expect(SetupStatus.addressCheck(PublicAddressCheck(outcome: .reachable, url: "https://pal.example.com")) == nil)
    }

    @Test(arguments: [
        (PublicAddressOutcome.notReachable, "NOT_REACHABLE", "Check that your Pal is online and that this address points to it."),
        (PublicAddressOutcome.wrongService, "WRONG_SERVICE", "Something else answered at this address."),
        (PublicAddressOutcome.notServed, "NOT_SERVED", "Your Pal is not serving web sign-in on this address yet."),
        (PublicAddressOutcome.noAddress, "NO_ADDRESS", "Pal has no web address saved yet."),
    ])
    func eachUnreachableOutcomeHasItsOwnPlainReason(outcome: PublicAddressOutcome, code: String, reason: String) throws {
        let status = try #require(SetupStatus.addressCheck(PublicAddressCheck(outcome: outcome)))
        #expect(status.title == "Pal could not reach this address")
        #expect(status.reason == reason)
        #expect(status.code == code)
        #expect(status.method == "webapp.public_url.check")
        #expect(status.actionTitle == "Check again")
    }

    @Test func aRefusedPastedAddressStaysOnTheField() {
        let status = SetupStatus.pasteRefused(note: "That address did not come from Google.")
        #expect(status.kind == .vendorRefusedValue)
        #expect(status.title == "That address did not work")
        #expect(status.reason == "That address did not come from Google.")
        #expect(status.actionTitle == "Edit address")
    }
}
