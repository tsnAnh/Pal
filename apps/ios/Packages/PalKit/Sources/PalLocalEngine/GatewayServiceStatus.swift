import Foundation

public struct GatewayServiceStatus: Sendable, Equatable, Decodable {
    public let installed: Bool
    public let loaded: Bool
    public let running: Bool
    public let pid: Int?
    public let startOnLogin: Bool
    public let label: String

    enum CodingKeys: String, CodingKey {
        case installed, loaded, running, pid, label
        case startOnLogin = "start_on_login"
    }

    public init(installed: Bool, loaded: Bool, running: Bool, pid: Int?, startOnLogin: Bool, label: String) {
        self.installed = installed
        self.loaded = loaded
        self.running = running
        self.pid = pid
        self.startOnLogin = startOnLogin
        self.label = label
    }

    static func parse(lines: [String]) -> GatewayServiceStatus? {
        guard let line = lines.last(where: { $0.hasPrefix("{") }) else { return nil }
        return try? JSONDecoder().decode(GatewayServiceStatus.self, from: Data(line.utf8))
    }
}
