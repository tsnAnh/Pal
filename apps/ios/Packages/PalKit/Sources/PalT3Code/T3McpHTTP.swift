import Foundation
import PalProtocol

struct T3McpOversize: Error {}

struct ServerSentEventDecoder {
    private var line = Data()
    private var dataLines: [Data] = []
    private var dataBytes = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func feed(_ byte: UInt8) throws -> Data? {
        guard byte == 0x0A else {
            line.append(byte)
            if line.count > limit { throw T3McpOversize() }
            return nil
        }
        if line.last == 0x0D { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let event = Data(dataLines.joined(separator: [0x0A]))
            dataLines.removeAll()
            dataBytes = 0
            return event
        }
        guard let field = Self.field(line), field.name == "data" else { return nil }
        dataBytes += field.value.count + 1
        if dataBytes > limit { throw T3McpOversize() }
        dataLines.append(field.value)
        return nil
    }

    private static func field(_ line: Data) -> (name: String, value: Data)? {
        guard line.first != 0x3A else { return nil }
        guard let colon = line.firstIndex(of: 0x3A) else { return (String(decoding: line, as: UTF8.self), Data()) }
        var value = line[line.index(after: colon)...]
        if value.first == 0x20 { value = value.dropFirst() }
        return (String(decoding: line[line.startIndex..<colon], as: UTF8.self), Data(value))
    }
}

final class T3McpHTTP: Sendable {
    static let protocolVersion = "2025-06-18"

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    private let session: URLSession
    private let delegate = NoRedirects()
    private let requestTimeout: TimeInterval

    init(requestTimeout: TimeInterval = 900) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 4
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.requestTimeout = requestTimeout
    }

    deinit {
        session.invalidateAndCancel()
    }

    private func request(_ method: String, _ url: URL, token: SecretString, sessionID: String?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token.reveal())", forHTTPHeaderField: "Authorization")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        return request
    }

    func post(_ url: URL, body: Data, token: SecretString, sessionID: String?) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = request("POST", url, token: token, sessionID: sessionID, timeout: requestTimeout)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (bytes, http)
    }

    func delete(_ url: URL, token: SecretString, sessionID: String) async {
        let request = request("DELETE", url, token: token, sessionID: sessionID, timeout: 5)
        _ = try? await session.data(for: request)
    }
}
