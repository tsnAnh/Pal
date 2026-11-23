#if os(macOS)
import Foundation
import PalBotProfile

struct ProviderTestFace: Equatable {
    enum Tone: Equatable {
        case neutral
        case success
        case failure
    }

    enum Indicator: Equatable {
        case none
        case spinner
        case check
        case cross
    }

    let slug: String
    let title: String
    let detail: String?
    let tone: Tone
    let indicator: Indicator
    let showsChecklist: Bool

    init(slug: String, title: String, detail: String? = nil, tone: Tone = .neutral, indicator: Indicator = .none, showsChecklist: Bool = false) {
        self.slug = slug
        self.title = title
        self.detail = detail
        self.tone = tone
        self.indicator = indicator
        self.showsChecklist = showsChecklist
    }

    static func make(state: ProviderTestState, provider: String, model: String, savesOnContinue: Bool, locale: Locale = .current) -> ProviderTestFace {
        switch state {
        case .idle, .signingIn, .awaitingTest: notTested
        case .testing: testing(model)
        case .slow: slow
        case .passed(let pass): passed(pass, savesOnContinue: savesOnContinue, locale: locale)
        case .failed(let reason, _): failed(reason)
        case .offline: offline(provider)
        case .modelChanged: modelChanged
        }
    }

    static func seconds(_ milliseconds: Int, locale: Locale = .current) -> String {
        let value = (Double(max(0, milliseconds)) / 1000).formatted(.number.precision(.fractionLength(1)).locale(locale))
        return String(localized: "\(value) s")
    }

    private static var notTested: ProviderTestFace {
        ProviderTestFace(slug: "notTested", title: String(localized: "Not tested yet"))
    }

    private static func testing(_ model: String) -> ProviderTestFace {
        ProviderTestFace(slug: "testing", title: String(localized: "Testing \(model)"), indicator: .spinner, showsChecklist: true)
    }

    private static var slow: ProviderTestFace {
        ProviderTestFace(
            slug: "slow", title: String(localized: "Still waiting after 10 s"),
            detail: String(localized: "Some models are slow to start. The test gives up at \(ProviderTestRequest.defaultTimeoutSeconds) s."),
            indicator: .spinner, showsChecklist: true)
    }

    private static func passed(_ pass: ProviderTestPass, savesOnContinue: Bool, locale: Locale) -> ProviderTestFace {
        let time = seconds(pass.latencyMilliseconds, locale: locale)
        let detail = savesOnContinue
            ? String(localized: "\(pass.model) replied in \(time): OK. Nothing is saved until you continue.")
            : String(localized: "\(pass.model) replied in \(time): OK. Pal uses it once you continue.")
        return ProviderTestFace(slug: "passed", title: String(localized: "Works"), detail: detail, tone: .success, indicator: .check)
    }

    private static func failed(_ reason: String) -> ProviderTestFace {
        ProviderTestFace(slug: "failed", title: String(localized: "Did not work"), detail: reason, tone: .failure, indicator: .cross)
    }

    private static func offline(_ provider: String) -> ProviderTestFace {
        ProviderTestFace(
            slug: "offline", title: String(localized: "No internet"),
            detail: String(localized: "This Mac is offline, so Pal could not reach \(provider). Connect and try again."), tone: .failure,
            indicator: .cross)
    }

    private static var modelChanged: ProviderTestFace {
        ProviderTestFace(
            slug: "modelChanged", title: String(localized: "Not tested for this model"),
            detail: String(localized: "You changed the model, so the earlier test no longer counts."))
    }
}

enum ProviderTestAction: Hashable {
    case skip
    case cancel
    case test
    case testing
    case testAgain
    case retry
    case saveAndContinue
    case signInAgain
    case changeKey
    case changeModel
    case remove
}

extension ProviderTestAction {
    var title: String {
        switch self {
        case .skip: String(localized: "Skip for now")
        case .cancel: String(localized: "Cancel")
        case .test: String(localized: "Test connection")
        case .testing: String(localized: "Testing")
        case .testAgain: String(localized: "Test again")
        case .retry: String(localized: "Retry")
        case .saveAndContinue: String(localized: "Save and continue")
        case .signInAgain: String(localized: "Sign in again")
        case .changeKey: String(localized: "Change key")
        case .changeModel: String(localized: "Change model")
        case .remove: String(localized: "Remove")
        }
    }

    var identifier: String {
        switch self {
        case .skip: "providerTestSkip"
        case .cancel: "providerTestCancel"
        case .test: "providerTestConnection"
        case .testing: "providerTestConnection"
        case .testAgain: "providerTestAgain"
        case .retry: "providerTestRetry"
        case .saveAndContinue: "providerTestSaveAndContinue"
        case .signInAgain: "providerTestSignInAgain"
        case .changeKey: "providerTestChangeKey"
        case .changeModel: "providerTestChangeModel"
        case .remove: "providerTestRemove"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .test, .testing, .retry, .saveAndContinue: true
        case .skip, .cancel, .testAgain, .signInAgain, .changeKey, .changeModel, .remove: false
        }
    }
}

struct ProviderTestFooterPlan: Equatable {
    struct Options: Equatable {
        var isStaged = false
        var keyed = false
        var canSignInAgain = false
        var canChangeModel = false
        var canRemove = false
    }

    let quiet: ProviderTestAction?
    let secondary: [ProviderTestAction]
    let primary: ProviderTestAction

    static func make(state: ProviderTestState, options: Options) -> ProviderTestFooterPlan {
        switch state {
        case .testing, .slow: ProviderTestFooterPlan(quiet: nil, secondary: [.cancel], primary: .testing)
        case .passed: ProviderTestFooterPlan(quiet: .skip, secondary: [.testAgain], primary: .saveAndContinue)
        case .failed(_, let kind): failed(kind, options)
        case .offline: ProviderTestFooterPlan(quiet: .skip, secondary: [], primary: .retry)
        case .idle, .signingIn, .awaitingTest, .modelChanged: ProviderTestFooterPlan(quiet: .skip, secondary: [], primary: .test)
        }
    }

    private static func failed(_ kind: ProviderTestFailureKind, _ options: Options) -> ProviderTestFooterPlan {
        var secondary: [ProviderTestAction] = []
        if kind == .auth {
            if options.keyed || options.isStaged {
                secondary.append(.changeKey)
            } else if options.canSignInAgain {
                secondary.append(.signInAgain)
            }
        }
        if kind == .model, options.canChangeModel { secondary.append(.changeModel) }
        if options.canRemove { secondary.append(.remove) }
        return ProviderTestFooterPlan(quiet: .skip, secondary: secondary, primary: .retry)
    }
}
#endif
