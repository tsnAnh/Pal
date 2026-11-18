import Foundation
import PalConnect
import Testing

@Suite("Setup status")
struct SetupStatusTests {
    @Test(arguments: [
        ("offline", SetupStatusClass.offline), ("timed_out", .offline), ("unreachable", .offline), ("UNREACHABLE", .offline),
        ("gateway_outdated", .gatewayOutdated), ("invalid_token", .vendorRefusedValue), ("credential_rejected", .vendorRefusedValue),
        ("INVALID_CLIENT", .vendorRefusedValue), ("needs_reauth", .needsReauth), ("revoked", .needsReauth),
        ("forbidden", .forbidden), ("NOT_OWNER", .forbidden), ("oauth_in_progress", .signInInProgress),
        ("invalid_redirect_uri", .invalidRedirect), ("internal", .internalFault), ("something_new", .internalFault), ("decode", .internalFault),
    ])
    func everyReasonCodeLandsInOneClass(code: String, expected: SetupStatusClass) {
        #expect(SetupStatusClass.classify(code: code) == expected)
        #expect(SetupStatus(code: code).kind == expected)
    }

    @Test func eachClassHasAPlainTitleReasonAndOneAction() {
        for kind in SetupStatusClass.allCases {
            let status = SetupStatus(code: kind.rawValue, subject: "Linear")
            #expect(status.kind == kind)
            #expect(!status.title.isEmpty && !status.reason.isEmpty && !status.actionTitle.isEmpty)
            #expect(!status.reason.contains(kind.rawValue))
        }
    }

    @Test func theMockupSentencesAreWhatThePersonReads() {
        let reauth = SetupStatus(code: "needs_reauth", subject: "Linear")
        #expect(reauth.title == "Sign-in expired")
        #expect(reauth.reason == "Linear needs you to sign in again.")
        #expect(reauth.actionTitle == "Reconnect")
        let token = SetupStatus(code: "invalid_token", subject: "Slack")
        #expect(token.title == "Slack did not accept that token")
        #expect(token.reason == "Copy the token again from Slack and paste it here.")
        #expect(token.actionTitle == "Edit token")
        let redirect = SetupStatus(code: "invalid_redirect_uri", subject: "Upwork", device: "Mac")
        #expect(redirect.title == "Upwork would not accept this Mac's address")
        let offline = SetupStatus(code: "offline")
        #expect(offline.title == "Can't reach your Pal")
        #expect(offline.actionTitle == "Try again")
        #expect(SetupStatus(code: "gateway_outdated").actionTitle == "Check again")
        #expect(SetupStatus(code: "forbidden").actionTitle == "Close")
        #expect(SetupStatus(code: "oauth_in_progress").actionTitle == "Connect")
    }

    @Test func aMissingSubjectStillReadsAsAPlainSentence() {
        #expect(SetupStatus(code: "invalid_token").title == "That token was not accepted")
        #expect(SetupStatus(code: "needs_reauth").reason == "This app needs you to sign in again.")
        #expect(SetupStatus(code: "invalid_token", valueName: "client secret").actionTitle == "Edit client secret")
    }

    @Test func detailsCarryCodeMethodTraceAndBothBuilds() {
        let status = SetupStatus(code: "invalid_redirect_uri", method: "mcp.servers.oauth.start", trace: "is6jx82q", gatewayVersion: "bbf2401c")
        #expect(status.detailsText(appBuild: "1.0 (1)") == """
            code: invalid_redirect_uri
            method: mcp.servers.oauth.start
            trace: is6jx82q
            app: 1.0 (1) · gateway bbf2401c
            """)
        #expect(SetupStatus(code: "forbidden").detailsText(appBuild: nil) == "code: forbidden")
    }
}
