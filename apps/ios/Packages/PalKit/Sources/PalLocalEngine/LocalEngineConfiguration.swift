import Foundation
import PalAuth

public struct LocalEngineConfiguration: Sendable, Equatable {
    public static let defaultPort = 9120
    public static let portSearchLimit = 24
    public static let repositoryURL = "https://github.com/tsnAnh/Pal.git"
    public static let branch = "main"

    public var hermesHome: URL
    public var installDirectory: URL
    public var userHome: URL
    public var preferredPort: Int
    public var repositoryURL: String
    public var branch: String

    public init(
        hermesHome: URL,
        installDirectory: URL? = nil,
        userHome: URL,
        preferredPort: Int = Self.defaultPort,
        repositoryURL: String = Self.repositoryURL,
        branch: String = Self.branch
    ) {
        self.hermesHome = hermesHome
        self.installDirectory = installDirectory ?? hermesHome.appending(path: "hermes-agent", directoryHint: .isDirectory)
        self.userHome = userHome
        self.preferredPort = preferredPort
        self.repositoryURL = repositoryURL
        self.branch = branch
    }

    public static var currentUserHome: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL.homeDirectory
        #endif
    }

    public static func standard(userHome: URL = currentUserHome) -> LocalEngineConfiguration {
        LocalEngineConfiguration(hermesHome: userHome.appending(path: ".hermes", directoryHint: .isDirectory), userHome: userHome)
    }

    public var launcher: URL {
        installDirectory.appending(path: ".hermes", directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: "hermes", directoryHint: .notDirectory)
    }

    public var sessionTokenFile: LocalSessionTokenFile {
        LocalSessionTokenFile(home: hermesHome)
    }

    public var installLog: URL {
        hermesHome.appending(path: "logs", directoryHint: .isDirectory).appending(path: "pal-app-install.log", directoryHint: .notDirectory)
    }

    public var launcherExists: Bool {
        FileManager.default.isExecutableFile(atPath: launcher.path)
    }

    public var incompleteInstallMarker: URL {
        hermesHome.appending(path: ".pal-install-incomplete", directoryHint: .notDirectory)
    }

    public var isInstalled: Bool {
        launcherExists && !FileManager.default.fileExists(atPath: incompleteInstallMarker.path)
    }
}

public enum LocalEngineOverrides {
    public static let homeArgument = "-hermes-test-engine-home"
    public static let directoryArgument = "-hermes-test-engine-dir"
    public static let userHomeArgument = "-hermes-test-engine-user-home"
    public static let portArgument = "-hermes-test-engine-port"
    public static let repositoryArgument = "-hermes-test-engine-repo"
    public static let branchArgument = "-hermes-test-engine-branch"

    public static func configuration(
        arguments: [String], base: LocalEngineConfiguration = .standard()
    ) -> LocalEngineConfiguration {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            let raw = arguments[index + 1]
            return raw.isEmpty ? nil : raw
        }
        var result = base
        if let userHome = value(userHomeArgument) {
            result.userHome = URL(filePath: userHome, directoryHint: .isDirectory)
        }
        if let home = value(homeArgument) {
            result.hermesHome = URL(filePath: home, directoryHint: .isDirectory)
            result.installDirectory = result.hermesHome.appending(path: "hermes-agent", directoryHint: .isDirectory)
        }
        if let directory = value(directoryArgument) {
            result.installDirectory = URL(filePath: directory, directoryHint: .isDirectory)
        }
        if let port = value(portArgument).flatMap(Int.init), (1...65_535).contains(port) {
            result.preferredPort = port
        }
        if let repository = value(repositoryArgument) { result.repositoryURL = repository }
        if let branch = value(branchArgument) { result.branch = branch }
        return result
    }
}
