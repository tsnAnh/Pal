#if os(macOS)
import PalAuth
import PalBotProfile

extension ProviderOnboardingModel {
    func notePasted() {
        clipboardMark = PasteboardScrub(SystemPasteboard()).mark()
    }

    func scrubPastedClipboard() {
        if let mark = clipboardMark { PasteboardScrub(SystemPasteboard()).clear(ifUnchangedSince: mark) }
        clipboardMark = nil
    }

    func cancelSignIn(_ providerID: String, decline: (String) async -> Void) async {
        scrubPastedClipboard()
        await decline(ModelProvidersClient.serviceKey + providerID)
        await back()
    }
}
#endif
