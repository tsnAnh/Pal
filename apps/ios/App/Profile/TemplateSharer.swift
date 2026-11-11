import PalBotProfile
import Foundation

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
            SharePresenter.present(items: [url]) { try? FileManager.default.removeItem(at: directory) }
        } catch is CancellationError {
        } catch {
            SharePresenter.alert(title: String(localized: "Couldn't share this template"), message: String(localized: "Try again in a moment."))
        }
    }
}
