import Foundation
import PalAuth

public enum T3RuntimeError: Error, Sendable, Equatable {
    case malformed
    case unsupportedVersion
    case notLoopback
}

public struct T3Runtime: Sendable, Equatable {
    public static let supportedVersion = 1

    public let origin: URL
    public let pid: Int32

    public var mcpURL: URL { origin.appending(path: "mcp") }

    public init(origin: URL, pid: Int32) {
        self.origin = origin
        self.pid = pid
    }

    private struct Document: Decodable {
        var version: Int
        var pid: Int32
        var origin: String
    }

    public static func parse(_ data: Data) throws -> T3Runtime {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { throw T3RuntimeError.malformed }
        guard document.version == supportedVersion else { throw T3RuntimeError.unsupportedVersion }
        guard document.pid > 0 else { throw T3RuntimeError.malformed }
        return T3Runtime(origin: try loopbackOrigin(document.origin), pid: document.pid)
    }

    static func loopbackOrigin(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text), components.scheme == "http",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, !host.isEmpty,
              let port = components.port
        else { throw T3RuntimeError.malformed }
        guard LoopbackHost.isLoopback(host) else { throw T3RuntimeError.notLoopback }
        guard (1...65535).contains(port) else { throw T3RuntimeError.malformed }
        var clean = URLComponents()
        clean.scheme = "http"
        clean.host = host
        clean.port = port
        guard let url = clean.url else { throw T3RuntimeError.malformed }
        return url
    }
}

public struct T3Locator: Sendable {
    public static let appNames = ["T3 Code (Beta).app", "T3 Code.app"]

    public let runtimeFile: URL
    public let applicationDirectories: [URL]
    public let processAlive: @Sendable (Int32) -> Bool

    public init(
        runtimeFile: URL,
        applicationDirectories: [URL],
        processAlive: @escaping @Sendable (Int32) -> Bool = T3Locator.systemProcessAlive
    ) {
        self.runtimeFile = runtimeFile
        self.applicationDirectories = applicationDirectories
        self.processAlive = processAlive
    }

    public static func standard(baseDirectory: URL? = nil) -> T3Locator {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let base = baseDirectory ?? home.appending(path: ".t3", directoryHint: .isDirectory)
        return T3Locator(
            runtimeFile: base.appending(path: "userdata/server-runtime.json"),
            applicationDirectories: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appending(path: "Applications", directoryHint: .isDirectory),
            ]
        )
    }

    public static let systemProcessAlive: @Sendable (Int32) -> Bool = { pid in
        kill(pid, 0) == 0 || errno == EPERM
    }

    public func runtime() -> T3Runtime? {
        guard let data = try? Data(contentsOf: runtimeFile), let runtime = try? T3Runtime.parse(data), processAlive(runtime.pid) else {
            return nil
        }
        return runtime
    }

    public func installedApplication() -> URL? {
        for directory in applicationDirectories {
            for name in Self.appNames {
                let candidate = directory.appending(path: name, directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
