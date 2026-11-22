import Foundation
import PalProtocol

enum T3AddressSuggestion {
    static func current() async -> String? {
        #if os(macOS)
        guard let port = await runtimePort(), let host = tailnetAddress() else { return nil }
        return "\(host):\(port)"
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func runtimePort() async -> Int? {
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".t3/userdata/server-runtime.json")
        guard let object = try? await DiskRead.json(contentsOf: file),
              let origin = object["origin"]?.stringValue,
              let port = URLComponents(string: origin)?.port, (1...65535).contains(port)
        else { return nil }
        return port
    }

    private static func tailnetAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard value >> 22 == 0x191 else { continue }
            return "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
        }
        return nil
    }
    #endif
}
