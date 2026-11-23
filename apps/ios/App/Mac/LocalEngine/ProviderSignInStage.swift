#if os(macOS)
import Foundation
import PalBotProfile
import PalDevice
import PalProtocol

enum ProviderSignInStage: Equatable {
    case starting
    case browser(canReopen: Bool)
    case code(String)
    case paste(note: String?, submitsAddress: Bool)
    case finishing
    case failed(String, canRetry: Bool, canPasteInstead: Bool)

    var slug: String {
        switch self {
        case .starting: "starting"
        case .browser: "browser"
        case .code: "code"
        case .paste: "paste"
        case .finishing: "finishing"
        case .failed: "failed"
        }
    }

    static func make(dialog: ServiceSignInDialog?, status: ModelProvidersModel.RowStatus) -> ProviderSignInStage {
        if case .failed(let text) = status { return .failed(text, canRetry: true, canPasteInstead: false) }
        guard let dialog else { return .starting }
        switch dialog.phase {
        case .prompting: return waiting(dialog, starting: true)
        case .signingIn: return waiting(dialog, starting: false)
        case .pasteAddress(let note): return .paste(note: note, submitsAddress: true)
        case .callbackFailed(let text): return .paste(note: text, submitsAddress: false)
        case .keySet, .signedIn: return .finishing
        case .keyFailed(let text), .failed(let text): return .failed(text, canRetry: false, canPasteInstead: dialog.canPasteInstead)
        case .expired: return .failed(String(localized: "The sign-in expired. Try again."), canRetry: false, canPasteInstead: false)
        }
    }

    private static func waiting(_ dialog: ServiceSignInDialog, starting: Bool) -> ProviderSignInStage {
        if dialog.flow == .deviceCode, let code = dialog.userCode { return .code(code) }
        if starting { return .starting }
        if dialog.flow == .oauthPaste { return .paste(note: nil, submitsAddress: false) }
        return .browser(canReopen: dialog.flow == .deviceCode && dialog.verificationURI != nil)
    }
}
#endif
