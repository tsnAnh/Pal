import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

enum ProfileSlackStatus: Equatable {
    case loading
    case notAdded
    case live(workspace: String?)
    case needsReinstall(workspace: String?)
    case unavailable

    init(_ result: ChatInstallStatusResult) {
        guard result.state.step == .ready else {
            self = .notAdded
            return
        }
        let workspace = result.installation?.workspaceName
        self = result.installation?.status == .needsReauth ? .needsReinstall(workspace: workspace) : .live(workspace: workspace)
    }

    init(_ connection: SlackConnection) {
        switch connection {
        case .connected: self = .live(workspace: nil)
        case .failed: self = .needsReinstall(workspace: nil)
        case .notConnected, .starting: self = .notAdded
        }
    }

    @MainActor
    static func load(botName: String, source: ChatInstallSource, services: BotsServices) async -> ProfileSlackStatus? {
        do {
            return ProfileSlackStatus(try await source.client.status(ChatInstallScope(provider: "slack", workspace: "")))
        } catch is CancellationError {
            return nil
        } catch ChatInstallClientError.unsupported {
            return (try? await services.slack.status(profile: botName)).map { ProfileSlackStatus($0.connection) } ?? .unavailable
        } catch {
            return .unavailable
        }
    }

    var title: String {
        self == .notAdded ? String(localized: "Add to Slack") : String(localized: "Slack")
    }
}

struct ProfileSlackValue: View {
    let status: ProfileSlackStatus

    var body: some View {
        switch status {
        case .notAdded:
            EmptyView()
        case .loading:
            ProgressView().controlSize(.small).accessibilityIdentifier("profileSlackLoading")
        case .unavailable:
            Text("Couldn't check")
                .foregroundStyle(PalTokens.textTertiary)
                .accessibilityIdentifier("profileSlackUnavailable")
        case .needsReinstall:
            Label { Text("Needs reinstall") } icon: { PalIcon("exclamationmark.triangle", ink: .secondary) }
                .foregroundStyle(Color.orange)
                .accessibilityIdentifier("profileSlackNeedsReinstall")
        case .live(let workspace):
            HStack(spacing: 4) {
                if let workspace { Text("In \(workspace)").foregroundStyle(PalTokens.textSecondary).lineLimit(1) }
                if workspace != nil { Text("·").foregroundStyle(PalTokens.textSecondary) }
                Text("● Live").foregroundStyle(Color.green).fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profileSlackLive")
        }
    }
}
