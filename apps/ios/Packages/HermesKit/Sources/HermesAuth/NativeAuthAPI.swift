import Foundation
import HermesDiagnostics
import HermesREST

public enum SignInError: Error, Sendable, Equatable {
    case randomnessUnavailable
    case listenerFailed
    case listenerTimedOut
    case cancelled
    case stateMismatch
    case missingAuthorizationCode
    case authorizationDenied(String)
    case browserUnavailable
    case sessionExpired
    case notSignedIn
}

struct NativeAuthAPI: Sendable {
    let baseURL: GatewayBaseURL
    let transport: any HTTPTransport
    let diagnostics: Diagnostics
    let now: @Sendable () -> Date
    var deviceID: String?

    private var boundDeviceID: String? {
        deviceID.flatMap { DeviceIdentity.isValid(deviceID: $0) ? $0 : nil }
    }

    private struct TokenBody: Encodable, Sendable {
        var code: String
        var codeVerifier: String
        var deviceID: String?

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case deviceID = "device_id"
        }
    }

    private struct RefreshBody: Encodable, Sendable {
        var refreshToken: String
        var provider: String
        var deviceID: String?

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case provider
            case deviceID = "device_id"
        }
    }

    private var client: RESTClient {
        RESTClient(baseURL: baseURL, transport: transport, diagnostics: diagnostics)
    }

    func authorizeURL(challenge: String, redirectURI: String, state: String) -> URL {
        baseURL.endpoint("/auth/native/authorize", query: [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ])
    }

    func exchange(code: String, verifier: String) async throws -> TokenSet {
        let payload = try await client.post(
            "/auth/native/token",
            body: TokenBody(code: code, codeVerifier: verifier, deviceID: boundDeviceID),
            as: TokenSet.Payload.self
        )
        return TokenSet(payload: payload, now: now())
    }

    func refresh(refreshToken: String, provider: String?) async throws -> TokenSet {
        do {
            let payload = try await client.post(
                "/auth/native/refresh",
                body: RefreshBody(refreshToken: refreshToken, provider: provider ?? "", deviceID: boundDeviceID),
                as: TokenSet.Payload.self
            )
            return TokenSet(payload: payload, now: now())
        } catch RESTError.unauthorized {
            throw SignInError.sessionExpired
        } catch RESTError.http(status: 401, _) {
            throw SignInError.sessionExpired
        }
    }
}
