import HermesBotProfile
import UIKit

@MainActor
final class TemplateSharer {
    private let services: BotsServices

    init(services: BotsServices) {
        self.services = services
    }

    func share(botName: String) async {
        do {
            let file = try await services.profiles.exportTemplate(for: botName)
            let directory = FileManager.default.temporaryDirectory.appending(path: "template-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: file.filename, directoryHint: .notDirectory)
            try file.data.write(to: url, options: [.atomic, .completeFileProtection])
            present(url: url, directory: directory)
        } catch is CancellationError {
        } catch {
            alert(title: String(localized: "Couldn't share this template"), message: String(localized: "Try again in a moment."))
        }
    }

    private func present(url: URL, directory: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: directory)
        }
        guard let top = Self.topViewController() else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.maxX - 44, y: top.view.safeAreaInsets.top + 22, width: 1, height: 1)
        top.present(controller, animated: true)
    }

    private func alert(title: String, message: String) {
        guard let top = Self.topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        top.present(alert, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = active?.keyWindow?.rootViewController ?? active?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
