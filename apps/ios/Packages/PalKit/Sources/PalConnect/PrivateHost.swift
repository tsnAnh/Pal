import Foundation

enum PrivateHost {
    static func isPrivate(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || isTailnetName(host) { return true }
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        guard let octets = ipv4(host) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func isTailnetName(_ host: String) -> Bool {
        let suffix = ".ts.net"
        return host.hasSuffix(suffix) && host.count > suffix.count
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        return octets
    }
}
