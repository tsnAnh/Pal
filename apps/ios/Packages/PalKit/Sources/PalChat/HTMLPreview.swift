import Foundation

public enum HTMLPreviewLimits {
    public static let liveRenderBytes = 5_000_000
    public static let loadTimeout: TimeInterval = 15

    public static func allowsLiveRender(size: Int) -> Bool { size <= liveRenderBytes }
}

public enum HTMLContentRules {
    public static let identifier = "pal.html.block-online"

    public static let blockOnline = """
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}}
    ]
    """
}

public struct HTMLExternalOpen: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case link
        case newWindow
        case download
        case page
    }

    public let url: URL
    public let reason: Reason

    public init(url: URL, reason: Reason) {
        self.url = url
        self.reason = reason
    }

    public var question: String {
        reason == .page ? "Open this page in your browser?" : "Open this link in your browser?"
    }

    public var detail: String {
        switch reason {
        case .link: url.absoluteString
        case .newWindow: "The page asked for a new window. \(url.absoluteString)"
        case .download: "The page asked to download a file. \(url.absoluteString)"
        case .page: "It will run outside Pal, without these limits."
        }
    }
}

public enum HTMLBlockedAction: Sendable, Equatable {
    case newWindow
    case download

    public var notice: String {
        switch self {
        case .newWindow: "A new window was blocked."
        case .download: "A download was blocked."
        }
    }
}

public enum HTMLPolicyDecision: Sendable, Equatable {
    case allow
    case cancel
    case confirmOpen(HTMLExternalOpen)
    case blocked(HTMLBlockedAction)
}

public struct HTMLNavigationPolicy: Sendable {
    private static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]
    private static let embeddedSchemes: Set<String> = ["data", "blob"]

    public let page: URL

    public init(page: URL) {
        self.page = page
    }

    public func navigation(to url: URL?, isMainFrame: Bool, onlineAllowed: Bool) -> HTMLPolicyDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case "about":
            return ["about:blank", "about:srcdoc"].contains(url.absoluteString) ? .allow : .cancel
        case "file":
            return url.resolvingSymlinksInPath().path == page.resolvingSymlinksInPath().path ? .allow : .cancel
        case "http", "https":
            if isMainFrame { return .confirmOpen(HTMLExternalOpen(url: url, reason: .link)) }
            return onlineAllowed ? .allow : .cancel
        case "mailto", "tel":
            return isMainFrame ? .confirmOpen(HTMLExternalOpen(url: url, reason: .link)) : .cancel
        default:
            return Self.embeddedSchemes.contains(scheme) && !isMainFrame ? .allow : .cancel
        }
    }

    public func newWindow(url: URL?) -> HTMLPolicyDecision {
        confirmation(url, reason: .newWindow, otherwise: .newWindow)
    }

    public func download(url: URL?) -> HTMLPolicyDecision {
        confirmation(url, reason: .download, otherwise: .download)
    }

    private func confirmation(_ url: URL?, reason: HTMLExternalOpen.Reason, otherwise: HTMLBlockedAction) -> HTMLPolicyDecision {
        guard let url, let scheme = url.scheme?.lowercased(), Self.openableSchemes.contains(scheme) else { return .blocked(otherwise) }
        return .confirmOpen(HTMLExternalOpen(url: url, reason: reason))
    }
}

public struct HTMLRenderState: Sendable, Equatable {
    public enum Failure: Sendable, Equatable {
        case timedOut
        case processTerminated
        case loadFailed
        case sandbox

        public var message: String {
            switch self {
            case .timedOut: "The page took too long to load."
            case .processTerminated: "The page stopped working."
            case .loadFailed: "The page couldn't be loaded."
            case .sandbox: "The page couldn't be opened safely."
            }
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case ready
        case failed(Failure)
    }

    public private(set) var phase = Phase.idle
    public private(set) var online = false
    public private(set) var generation = 0

    public init() {}

    public var onlineLabel: String { online ? "Online allowed" : "Online blocked" }
    public var onlineActionLabel: String { online ? "Block again" : "Allow online" }

    @discardableResult
    public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        reload()
        return true
    }

    public mutating func finish() {
        if phase == .loading { phase = .ready }
    }

    public mutating func fail(_ failure: Failure) {
        switch phase {
        case .loading, .ready: phase = .failed(failure)
        case .idle, .failed: break
        }
    }

    @discardableResult
    public mutating func retry() -> Bool {
        guard case .failed = phase else { return false }
        reload()
        return true
    }

    @discardableResult
    public mutating func toggleOnline() -> Bool {
        guard phase != .idle else { return false }
        online.toggle()
        reload()
        return true
    }

    private mutating func reload() {
        phase = .loading
        generation += 1
    }
}
