import Foundation
import HermesAuth
import HermesREST
import Synchronization

struct LiveGateway {
    let baseURL: GatewayBaseURL
    let username: String
    let password: String

    static func fromEnvironment() -> LiveGateway? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HERMES_IOS_TEST_BASE_URL"], let username = env["HERMES_IOS_TEST_USERNAME"],
              let password = env["HERMES_IOS_TEST_PASSWORD"], let baseURL = try? GatewayBaseURL(validating: raw)
        else { return nil }
        return LiveGateway(baseURL: baseURL, username: username, password: password)
    }

    static var isConfigured: Bool { fromEnvironment() != nil }
}

final class RecordingTransport: HTTPTransport {
    struct Exchange: Sendable {
        var url: URL
        var method: String
        var authorization: String?
        var requestBody: Data?
        var status: Int
        var responseBody: Data
    }

    private let inner: any HTTPTransport
    private let log = Mutex<[Exchange]>([])

    init(_ inner: any HTTPTransport = URLSessionHTTPTransport()) {
        self.inner = inner
    }

    var exchanges: [Exchange] { log.withLock { $0 } }

    func count(path: String) -> Int {
        exchanges.filter { $0.url.path == path }.count
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let result = try await inner.send(request)
        log.withLock {
            $0.append(Exchange(
                url: request.url!,
                method: request.httpMethod ?? "GET",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                requestBody: request.httpBody,
                status: result.response.statusCode,
                responseBody: result.data
            ))
        }
        return result
    }

    var secrets: Set<String> {
        var found: Set<String> = []
        let keys: Set<String> = ["access_token", "refresh_token", "code_verifier", "code", "ticket"]
        for exchange in exchanges {
            if let header = exchange.authorization { found.insert(String(header.dropFirst("Bearer ".count))) }
            if let query = URLComponents(url: exchange.url, resolvingAgainstBaseURL: false)?.queryItems {
                for item in query where item.name == "state" || item.name == "code_challenge" {
                    if let value = item.value { found.insert(value) }
                }
            }
            for body in [exchange.requestBody, exchange.responseBody] {
                guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
                for key in keys {
                    if let value = object[key] as? String, !value.isEmpty { found.insert(value) }
                }
            }
        }
        return found.filter { $0.count >= 8 }
    }
}

final class ProgrammaticBrowser: AuthorizationBrowser {
    private let username: String
    private let password: String
    private let dismissals = Mutex(0)
    private let authorizeURLs = Mutex<[URL]>([])
    private let callbackURLs = Mutex<[URL]>([])

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var dismissCount: Int { dismissals.withLock { $0 } }
    var authorizeURL: URL? { authorizeURLs.withLock { $0.first } }
    var callbackURL: URL? { callbackURLs.withLock { $0.first } }

    func present(_ url: URL) async throws {
        authorizeURLs.withLock { $0.append(url) }
        let driver = BrowserDriver()
        try await driver.signIn(authorizeURL: url, username: username, password: password) { callback in
            self.callbackURLs.withLock { $0.append(callback) }
        }
        try await Task.sleep(for: .seconds(120))
    }

    func dismiss() async {
        dismissals.withLock { $0 += 1 }
    }
}

private final class BrowserDriver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    func signIn(
        authorizeURL: URL,
        username: String,
        password: String,
        onCallback: @Sendable (URL) -> Void
    ) async throws {
        defer { session.finishTasksAndInvalidate() }
        let (_, authorizeResponse) = try await session.data(from: authorizeURL)
        guard let authorizeHTTP = authorizeResponse as? HTTPURLResponse, authorizeHTTP.statusCode == 302 else {
            throw DriverError.unexpected("authorize")
        }
        var login = URLRequest(url: URL(string: "/auth/password-login", relativeTo: authorizeURL)!.absoluteURL)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["provider": "basic", "username": username, "password": password])
        let (body, loginResponse) = try await session.data(for: login)
        guard (loginResponse as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let next = object["next"] as? String, let callback = URL(string: next)
        else { throw DriverError.unexpected("password-login") }
        onCallback(callback)
        let (_, callbackResponse) = try await session.data(from: callback)
        guard (callbackResponse as? HTTPURLResponse)?.statusCode == 200 else { throw DriverError.unexpected("callback") }
    }

    enum DriverError: Error { case unexpected(String) }
}
