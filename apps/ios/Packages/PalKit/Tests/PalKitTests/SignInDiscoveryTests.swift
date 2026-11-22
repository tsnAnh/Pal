import Foundation
import PalAuth
import PalREST
import Testing

private struct ProvidersTransport: HTTPTransport {
    let status: Int
    let body: String

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return HTTPResult(data: Data(body.utf8), response: response)
    }
}

private struct OfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cannotConnectToHost) }
}

private func discover(status: Int = 200, _ body: String) async throws -> SignInDiscovery {
    let baseURL = try GatewayBaseURL(validating: "https://pal.example.test")
    return await NativeSignIn(transport: ProvidersTransport(status: status, body: body)).discoverOptions(baseURL: baseURL)
}

@Suite("Sign-in discovery")
struct SignInDiscoveryTests {
    @Test func emptyProviderListMeansNoMethods() async throws {
        #expect(try await discover(#"{"providers":[]}"#) == .noMethods)
    }

    @Test func namelessEntriesAreDropped() async throws {
        let result = try await discover(#"{"providers":[{"name":"","display_name":"Ghost","supports_password":true},{"name":"  ","supports_password":false}]}"#)
        #expect(result == .noMethods)
    }

    @Test func browserOnlyProvidersOfferNoPalAccount() async throws {
        let result = try await discover(
            #"{"providers":[{"name":"nous","display_name":"Nous Research","supports_password":false},"#
                + #"{"name":"corp","display_name":"Corp SSO"}]}"#
        )
        #expect(result == .noMethods)
    }

    @Test func thePasswordProviderIsThePalAccount() async throws {
        let result = try await discover(
            #"{"providers":[{"name":"nous","display_name":"Nous Research","supports_password":false},"#
                + #"{"name":"basic","display_name":"Username & Password","supports_password":true}]}"#
        )
        #expect(result == .ready(SignInOption(id: "basic")))
    }

    @Test func httpFailureIsUnreachable() async throws {
        #expect(try await discover(status: 503, #"{"detail":"down"}"#) == .unreachable)
    }

    @Test func malformedBodyIsUnreachable() async throws {
        #expect(try await discover("not json") == .unreachable)
    }

    @Test func transportFailureIsUnreachable() async throws {
        let baseURL = try GatewayBaseURL(validating: "https://pal.example.test")
        #expect(await NativeSignIn(transport: OfflineTransport()).discoverOptions(baseURL: baseURL) == .unreachable)
    }
}
