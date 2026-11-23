import Foundation
import Security

public struct EngineFailure: Error, Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case install
        case start
        case remove
    }

    public let operation: Operation
    public let step: InstallStep?
    public let resumeStage: String?
    public let code: String
    public let reason: String
    public let trace: String

    public var title: String {
        switch operation {
        case .install: String(localized: "Couldn't install Pal")
        case .start: String(localized: "Couldn't start Pal")
        case .remove: String(localized: "Couldn't remove Pal")
        }
    }

    public var actionTitle: String { String(localized: "Try again") }

    public static func makeTrace() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func install(stage: InstallStage, report: StageReport?, trace: String) -> EngineFailure {
        let kind = InstallFailureKind.classify(reason: report?.reason)
        return EngineFailure(
            operation: .install, step: stage.step, resumeStage: stage.name, code: kind.code(for: stage.step), reason: kind.reason(for: stage.step),
            trace: trace
        )
    }

    public static func installerUnavailable(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .install, step: .download, resumeStage: nil, code: "install_unavailable",
            reason: String(localized: "Pal couldn't start its installer. Quit Pal, open it again and try once more."), trace: trace
        )
    }

    public static func configuration(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: .startPal, resumeStage: nil, code: "config_failed",
            reason: String(localized: "Pal couldn't save its settings. Check that your Mac has free space, then try again."), trace: trace
        )
    }

    public static func gatewayInstall(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: .startPal, resumeStage: nil, code: "gateway_install_failed",
            reason: String(localized: "macOS wouldn't let Pal keep running in the background. Try again, or restart your Mac."), trace: trace
        )
    }

    public static func portInUse(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: .startPal, resumeStage: nil, code: "port_in_use",
            reason: String(localized: "Another program on this Mac is using the connection Pal needs. Quit it, then try again."), trace: trace
        )
    }

    public static func loginSetting(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: nil, resumeStage: nil, code: "login_setting_failed",
            reason: String(localized: "Pal couldn't change that setting. Try again."), trace: trace
        )
    }

    public static func tailnet(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: nil, resumeStage: nil, code: "tailnet_failed",
            reason: String(localized: "Pal couldn't change iPhone access. Try again."), trace: trace
        )
    }

    public static func engineNotResponding(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: .startPal, resumeStage: nil, code: "service_not_responding",
            reason: String(localized: "Pal started but isn't answering yet. Try again in a moment."), trace: trace
        )
    }

    public static func signInFailed(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: .startPal, resumeStage: nil, code: "signin_failed",
            reason: String(localized: "Pal is running, but signing you in didn't work. Try again."), trace: trace
        )
    }

    public static func unexpected(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .install, step: nil, resumeStage: nil, code: "unexpected",
            reason: String(localized: "Something went wrong. Try again."), trace: trace
        )
    }

    public static func removalFailed(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .remove, step: nil, resumeStage: nil, code: "remove_failed",
            reason: String(localized: "Pal couldn't be removed. Try again."), trace: trace
        )
    }

    public static func tokenUnavailable(trace: String) -> EngineFailure {
        EngineFailure(
            operation: .start, step: .startPal, resumeStage: nil, code: "token_unavailable",
            reason: String(localized: "Pal started, but its sign-in on this Mac couldn't be read. Try again."), trace: trace
        )
    }
}

enum InstallFailureKind: Equatable {
    case generic
    case gitMissing
    case diskFull

    private static let signatures: [(needle: String, kind: InstallFailureKind)] = [
        ("git is required", .gitMissing),
        ("git is installed but cannot run", .gitMissing),
        ("no space left", .diskFull),
        ("disk full", .diskFull),
    ]

    static func classify(reason: String?) -> InstallFailureKind {
        guard let reason = reason?.lowercased() else { return .generic }
        return signatures.first { reason.contains($0.needle) }?.kind ?? .generic
    }

    func code(for step: InstallStep) -> String {
        switch self {
        case .gitMissing: "install_git_missing"
        case .diskFull: "install_disk_full"
        case .generic:
            switch step {
            case .download: "install_download_failed"
            case .preparePython: "install_python_failed"
            case .installComponents: "install_components_failed"
            case .setUp, .startPal: "install_setup_failed"
            }
        }
    }

    func reason(for step: InstallStep) -> String {
        switch self {
        case .gitMissing:
            String(localized: "Pal needs Apple's developer tools to download itself. Install them when macOS offers, then try again.")
        case .diskFull:
            String(localized: "Your Mac is out of space. Free some up, then try again.")
        case .generic:
            switch step {
            case .download: String(localized: "The download stopped. Check your internet connection and try again.")
            case .preparePython: String(localized: "Pal couldn't prepare its Python tools. Check your internet connection and try again.")
            case .installComponents:
                String(localized: "Pal couldn't install all of its components. Check your internet connection and free space, then try again.")
            case .setUp, .startPal: String(localized: "Pal couldn't finish setting itself up. Try again.")
            }
        }
    }
}
