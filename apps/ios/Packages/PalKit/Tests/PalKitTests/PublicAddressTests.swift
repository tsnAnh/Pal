import Foundation
@testable import PalConnect
import PalProtocol
import PalTransport
import Testing

private let accepted: [(String, String)] = [
    ("https://pal.tail1234.ts.net", "https://pal.tail1234.ts.net"),
    ("https://pal.tail1234.ts.net/", "https://pal.tail1234.ts.net"),
    ("  HTTPS://Pal.Tail1234.TS.net/ ", "https://pal.tail1234.ts.net"),
    ("https://pal.example.com:8443", "https://pal.example.com:8443"),
    ("https://pal.example.com.", "https://pal.example.com"),
]

private let rejected: [(String, PublicAddress.Problem)] = [
    ("pal.example.com", .notHTTPS),
    ("http://pal.example.com", .notHTTPS),
    ("ftp://pal.example.com", .notHTTPS),
    ("https://user:pw@pal.example.com", .userinfo),
    ("https://user@pal.example.com", .userinfo),
    ("https://100.101.102.103", .ipHost),
    ("https://[fd7a:115c:a1e0::1]", .ipHost),
    ("https://localhost", .invalidHost),
    ("https://bad_host.example.com", .invalidHost),
    ("https://-pal.example.com", .invalidHost),
    ("https://pal.example.com/app", .path),
    ("https://pal.example.com//", .path),
    ("https://pal.example.com/?a=1", .queryOrFragment),
    ("https://pal.example.com?a=1", .queryOrFragment),
    ("https://pal.example.com/#top", .queryOrFragment),
    ("https://pal.example.com#", .queryOrFragment),
    ("https://pal example.com", .invalid),
    ("https://pal.example.com:0", .invalid),
    ("https://pal.example.com:99999", .invalid),
    ("https://" + String(repeating: "a", count: 250) + ".example.com", .tooLong),
]

@Suite("Public address validation")
struct PublicAddressValidationTests {
    @Test(arguments: accepted)
    func acceptsAndNormalises(raw: String, stored: String) {
        #expect(PublicAddress.evaluate(raw) == .address(stored))
    }

    @Test(arguments: rejected)
    func rejectsEachRule(raw: String, problem: PublicAddress.Problem) {
        #expect(PublicAddress.evaluate(raw) == .refused(problem))
    }

    @Test func emptyInputClearsTheAddress() {
        #expect(PublicAddress.evaluate("") == .clear)
        #expect(PublicAddress.evaluate("  \n ") == .clear)
    }

    @Test func everyProblemHasPlainLanguageAndMatchesTheGatewayName() {
        #expect(Set(PublicAddress.Problem.allCases.map(\.rawValue)) == [
            "too_long", "invalid", "not_https", "userinfo", "ip_host", "invalid_host", "path", "query_or_fragment",
        ])
        for problem in PublicAddress.Problem.allCases { #expect(!problem.message.isEmpty && !problem.message.contains("_")) }
    }
}

private let stateReply: CustomRPC.Reply = { _ in
    ["url": "https://pal.example.test", "routes_enabled": false, "suggestion": "https://pal.tail1234.ts.net"]
}

@Suite("Public address calls")
struct PublicAddressServiceTests {
    @Test func getReadsTheSavedAddressRoutesAndSuggestionForTheScopedProfile() async throws {
        let rpc = CustomRPC(["webapp.public_url.get": stateReply])
        let state = try await customService(rpc, profile: "alpha").publicAddress()
        #expect(state == PublicAddressState(url: "https://pal.example.test", routesEnabled: false, suggestion: "https://pal.tail1234.ts.net"))
        let sent = try #require(rpc.params("webapp.public_url.get").first)
        #expect(sent["profile"]?.stringValue == "alpha")
    }

    @Test func aMissingAddressAndSuggestionDecodeAsNil() async throws {
        let rpc = CustomRPC(["webapp.public_url.get": { _ in ["url": .null, "routes_enabled": true] }])
        #expect(try await customService(rpc).publicAddress() == PublicAddressState(url: nil, routesEnabled: true, suggestion: nil))
    }

    @Test func setSendsTheNormalisedUrlAndAnEmptyOneClears() async throws {
        let rpc = CustomRPC(["webapp.public_url.set": stateReply])
        let service = customService(rpc)
        _ = try await service.savePublicAddress("https://pal.example.test")
        _ = try await service.savePublicAddress("")
        #expect(rpc.params("webapp.public_url.set").map { $0["url"]?.stringValue } == ["https://pal.example.test", ""])
    }

    @Test func checkDecodesEveryOutcome() async throws {
        for outcome in PublicAddressOutcome.allCases {
            let rpc = CustomRPC(["webapp.public_url.check": { _ in ["outcome": .string(outcome.rawValue), "url": "https://pal.example.test"] }])
            let check = try await customService(rpc).checkPublicAddress()
            #expect(check == PublicAddressCheck(outcome: outcome, url: "https://pal.example.test"))
        }
    }

    @Test func anUnknownOutcomeIsAFailureNotAGuess() async {
        let rpc = CustomRPC(["webapp.public_url.check": { _ in ["outcome": "maybe"] }])
        await #expect(throws: ConnectAppsError.failed) { _ = try await customService(rpc).checkPublicAddress() }
    }

    @Test func aRefusedValueNamesTheProblemAndKeepsTheTrace() async throws {
        let refusal: CustomRPC.Reply = { _ in
            throw GatewayTransportError.rpc(RPCError(
                code: 4000, message: "invalid_params",
                data: ["reason": "invalid_params", "field": "url", "problem": "ip_host", "trace": "ab12cd34"]
            ))
        }
        let rpc = CustomRPC(["webapp.public_url.set": refusal])
        do {
            _ = try await customService(rpc).savePublicAddress("https://100.101.102.103")
            Issue.record("expected a refusal")
        } catch let error as PublicAddressError {
            #expect(error.reason == .refused(.ipHost))
            #expect(error.fault?.trace.rawValue == "ab12cd34" && error.fault?.method == "webapp.public_url.set")
        }
    }

    @Test func ownerOnlyAndManagedAreDistinctFromAnyOtherFailure() async {
        let cases: [(Int, PublicAddressError.Reason)] = [(4403, .ownerOnly), (4030, .managed), (5000, .other)]
        for (code, reason) in cases {
            let rpc = CustomRPC(["webapp.public_url.get": rpcFailure(code, reason: "x")])
            do {
                _ = try await customService(rpc).publicAddress()
                Issue.record("expected a failure")
            } catch let error as PublicAddressError {
                #expect(error.reason == reason)
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func aDroppedConnectionIsAnUnreachableFailureWithATransportFault() async {
        let rpc = CustomRPC(["webapp.public_url.get": { _ in throw GatewayTransportError.timedOut }])
        do {
            _ = try await customService(rpc).publicAddress()
            Issue.record("expected a failure")
        } catch let error as PublicAddressError {
            #expect(error.reason == .other && error.fault?.source == .transport)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
