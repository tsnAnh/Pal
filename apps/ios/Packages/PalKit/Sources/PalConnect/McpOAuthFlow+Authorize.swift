import Foundation

extension McpOAuthFlow {
    public static let accountPrompt = "select_account login"

    public func selectingAccount(_ selects: Bool) -> McpOAuthFlow {
        var copy = self
        copy.selectsAccount = selects
        return copy
    }

    func accountPrompted(_ url: URL) -> URL {
        Self.addingPrompt(selectsAccount ? Self.accountPrompt : nil, to: url)
    }

    static func addingPrompt(_ prompt: String?, to url: URL) -> URL {
        guard let prompt, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "prompt" }) else { return url }
        items.append(URLQueryItem(name: "prompt", value: prompt))
        components.queryItems = items
        return components.url ?? url
    }
}
