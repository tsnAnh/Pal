import Foundation
import PalProtocol

public struct ProviderHostCheck: Sendable, Equatable, Decodable {
    public enum Stage: Sendable, Equatable {
        case cliMissing
        case notSignedIn
        case pluginMissing
        case ready
    }

    public let cliFound: Bool
    public let cliVersion: String?
    public let signedIn: Bool
    public let plan: String?
    public let pluginInstalled: Bool
    public let pluginVersion: String?
    public let installHint: String?
    public let disclosure: String?

    public init(
        cliFound: Bool, cliVersion: String? = nil, signedIn: Bool, plan: String? = nil, pluginInstalled: Bool,
        pluginVersion: String? = nil, installHint: String? = nil, disclosure: String? = nil
    ) {
        self.cliFound = cliFound
        self.cliVersion = cliVersion
        self.signedIn = signedIn
        self.plan = plan
        self.pluginInstalled = pluginInstalled
        self.pluginVersion = pluginVersion
        self.installHint = installHint
        self.disclosure = disclosure
    }

    enum CodingKeys: String, CodingKey {
        case plan, disclosure
        case cliFound = "cli_found"
        case cliVersion = "cli_version"
        case signedIn = "signed_in"
        case pluginInstalled = "plugin_installed"
        case pluginVersion = "plugin_version"
        case installHint = "install_hint"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliFound = try container.decodeIfPresent(Bool.self, forKey: .cliFound) ?? false
        cliVersion = try Self.text(container, .cliVersion)
        signedIn = try container.decodeIfPresent(Bool.self, forKey: .signedIn) ?? false
        plan = try Self.text(container, .plan)
        pluginInstalled = try container.decodeIfPresent(Bool.self, forKey: .pluginInstalled) ?? false
        pluginVersion = try Self.text(container, .pluginVersion)
        installHint = try Self.text(container, .installHint)
        disclosure = try Self.text(container, .disclosure)
    }

    private static func text(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
        try container.decodeIfPresent(String.self, forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    public var stage: Stage {
        if !cliFound { return .cliMissing }
        if !signedIn { return .notSignedIn }
        if !pluginInstalled { return .pluginMissing }
        return .ready
    }
}

public enum ProviderHostCheckResult: Sendable, Equatable {
    case checked(ProviderHostCheck)
    case failed(String)
}

public enum ProviderPluginInstall: Sendable, Equatable {
    case installed(ModelProvider?)
    case refused(String)
    case failed(String)
}

extension ModelProvidersClient {
    public func hostCheck(_ provider: String) async -> ProviderHostCheckResult {
        do {
            let result = try await gateway.call("model.providers.host_check", scoped(["provider": .string(provider)]))
            return .checked(try gateway.decoded(ProviderHostCheck.self, result))
        } catch {
            return .failed(Self.couldNotCheckHost)
        }
    }

    public func installPlugin(_ provider: String) async -> ProviderPluginInstall {
        do {
            let action = try await perform("model.providers.install_plugin", ["provider": .string(provider)])
            let reason = action.reason ?? Self.couldNotInstallPlugin
            switch action.outcome {
            case "installed", "already_installed": return .installed(action.provider)
            case "refused": return .refused(reason)
            default: return .failed(reason)
            }
        } catch {
            return .failed(Self.couldNotInstallPlugin)
        }
    }

    static let couldNotCheckHost = "Couldn't check the computer that runs Pal. Try again in a moment."
    static let couldNotInstallPlugin = "Couldn't install the plugin. Try again in a moment."
}
