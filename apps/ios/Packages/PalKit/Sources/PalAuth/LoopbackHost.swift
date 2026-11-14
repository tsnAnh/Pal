import Foundation

public enum LoopbackHost {
    public static func isLoopback(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        switch bare.lowercased() {
        case "127.0.0.1", "localhost", "::1": return true
        default: return false
        }
    }

    public static func isLoopback(_ url: URL) -> Bool {
        url.host().map(isLoopback) ?? false
    }
}
