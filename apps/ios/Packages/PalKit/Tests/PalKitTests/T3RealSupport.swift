import Foundation
import PalAuth
@testable import PalConnect
import Testing

enum RealT3 {
    static let baseDirectory = ProcessInfo.processInfo.environment["PAL_T3_E2E_BASE_DIR"]
    static let pairingCode = ProcessInfo.processInfo.environment["PAL_T3_E2E_PAIRING_CODE"]
    static var enabled: Bool { baseDirectory != nil && pairingCode != nil }
}

struct ApprovingBrowser: AuthorizationBrowser {
    let origin: @Sendable () -> URL
    let pairingCode: @Sendable () -> String

    func present(_ url: URL) async throws {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let wanted = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "resource"]
        var authorization: [String: String] = [:]
        for item in components.queryItems ?? [] where wanted.contains(item.name) { authorization[item.name] = item.value }
        let body: [String: Any] = [
            "authorization": authorization,
            "decision": ["_tag": "pairing-code", "access": "approval-required", "code": pairingCode()],
        ]
        var request = URLRequest(url: origin().appending(path: "oauth/mcp/decision"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let redirect = try #require(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["redirectTo"] as? String)
        let callback = try #require(URL(string: redirect))
        #expect(callback.host() == "127.0.0.1")
        _ = try? await URLSession.shared.data(from: callback)
        try await Task.sleep(for: .seconds(60))
    }

    func dismiss() async {}
}
