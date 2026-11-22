import Foundation
import PalProtocol

public enum ChatInstallLink: Sendable, Hashable {
    case installDone

    public init?(url: URL, scheme: PalURLScheme = .current) {
        guard url.scheme?.lowercased() == scheme.rawValue, url.host(percentEncoded: false)?.lowercased() == "chat",
              url.path(percentEncoded: false) == "/install-done", url.user == nil, url.port == nil else { return nil }
        self = .installDone
    }
}
