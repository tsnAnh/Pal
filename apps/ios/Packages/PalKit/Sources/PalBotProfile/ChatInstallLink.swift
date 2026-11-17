import Foundation

public enum ChatInstallLink: Sendable, Hashable {
    case installDone

    public static let scheme = "dev.tsnanh.hermes.bot"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host(percentEncoded: false)?.lowercased() == "chat",
              url.path(percentEncoded: false) == "/install-done", url.user == nil, url.port == nil else { return nil }
        self = .installDone
    }
}
