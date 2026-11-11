import Foundation
import HermesProtocol

extension DeviceToolExecutor {
    private static let browserReserve: Duration = .seconds(2)
    private static let credentialFieldHint = "password|passwd|passcode|\\bpwd\\b|one-time|\\botp\\b"

    private func pageWire(_ page: BrowserPageRecord) throws -> JSONValue {
        let text = TextCap.finish(page.text, limit: DeviceTextLimit.fileContent)
        return try DeviceWire.encode(BrowserPageWire(
            url: page.url, title: page.title, text: text.text, loginRequired: page.loginRequired,
            truncated: text.truncated, matched: page.matched
        ))
    }

    static func webURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty else {
            throw DeviceProviderError.invalidArgs("Only http and https pages can be opened.")
        }
        return url
    }

    func openPage(_ raw: JSONValue, budget: Duration) async throws -> JSONValue {
        let args: BrowserOpenArgs = try DeviceWire.decodeArgs(raw)
        let url = try Self.webURL(args.url)
        let timeout = max(budget - Self.browserReserve, .seconds(1))
        return try pageWire(try await provider(\.browser).open(url: url, captureLimit: DeviceTextLimit.fileContent, timeout: timeout))
    }

    func readPage(budget: Duration) async throws -> JSONValue {
        try pageWire(try await provider(\.browser).read(captureLimit: DeviceTextLimit.fileContent))
    }

    func clickPage(_ raw: JSONValue, budget: Duration) async throws -> JSONValue {
        let args: BrowserClickArgs = try DeviceWire.decodeArgs(raw)
        let selector = args.selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = args.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (selector?.isEmpty == false) != (label?.isEmpty == false) else {
            throw DeviceProviderError.invalidArgs("Pass exactly one of selector or text.")
        }
        return try pageWire(try await provider(\.browser).click(selector: selector, text: label, captureLimit: DeviceTextLimit.fileContent))
    }

    func typeIntoPage(_ raw: JSONValue, budget: Duration) async throws -> JSONValue {
        let args: BrowserTypeArgs = try DeviceWire.decodeArgs(raw)
        let selector = args.selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { throw DeviceProviderError.invalidArgs("selector is required.") }
        guard selector.range(of: Self.credentialFieldHint, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw DeviceProviderError.invalidArgs("Typing into a password field is refused. Ask the user to type it on this Mac.")
        }
        return try pageWire(try await provider(\.browser).type(
            selector: selector, text: args.text, submit: args.submit ?? false, captureLimit: DeviceTextLimit.fileContent
        ))
    }

    func waitForText(_ raw: JSONValue, budget: Duration) async throws -> JSONValue {
        let args: BrowserWaitForTextArgs = try DeviceWire.decodeArgs(raw)
        let needle = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw DeviceProviderError.invalidArgs("text is required.") }
        let seconds = Self.clamp(args.timeoutSeconds, 15, 1...60)
        let timeout = max(min(Duration.seconds(seconds), budget - Self.browserReserve), .milliseconds(500))
        return try pageWire(try await provider(\.browser).waitForText(needle, timeout: timeout, captureLimit: DeviceTextLimit.fileContent))
    }

    func closePage() async throws -> JSONValue {
        try await provider(\.browser).close()
        return try DeviceWire.encode(["closed": true])
    }
}
