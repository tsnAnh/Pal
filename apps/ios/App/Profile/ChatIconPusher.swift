import CoreGraphics
import Foundation
import ImageIO
import PalBotProfile
import PalDesign
import PalDiagnostics
import PalProtocol
import UniformTypeIdentifiers

struct ChatIconPusher: Sendable {
    static let provider = "slack"

    let client: any ChatInstallClient

    private var scope: ChatInstallScope { ChatInstallScope(provider: Self.provider, workspace: "") }

    @MainActor
    func push(_ spec: BotAvatarSpec, onlyWhenInstalled: Bool) async {
        let diagnostics = Diagnostics.osLog()
        do {
            if onlyWhenInstalled {
                guard try await client.status(scope).state.step == .ready else { return }
            }
            guard let image = ChatAvatarExport.render(spec: spec, background: PalTokens.content),
                  let png = await Self.pngData(image) else {
                diagnostics.warning("chat-icon", "render failed")
                return
            }
            try await client.setIcon(scope, png: png)
        } catch is CancellationError {
        } catch {
            diagnostics.warning("chat-icon", "push failed: \(Diagnostics.describe(error))")
        }
    }

    private static func pngData(_ image: CGImage) async -> Data? {
        await Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }.value
    }
}

extension RosterModel {
    func pushChatIcon(for name: String, spec: BotAvatarSpec?) {
        guard let spec = spec ?? bot(named: name)?.spec else { return }
        let pusher = ChatIconPusher(client: ChatInstallSource.make(botName: name, connection: connection).client)
        Task { await pusher.push(spec, onlyWhenInstalled: true) }
    }
}
