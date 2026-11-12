import Foundation

public enum ScreenLimits {
    public static let longEdge = 1568
    public static let maximumImageBytes = 300_000
    public static let maximumTextCharacters = 24_000
    public static let minimumInterval: Duration = .seconds(3)
}

public struct ScreenFrame: Sendable, Equatable {
    public var jpeg: Data
    public var width: Int
    public var height: Int

    public init(jpeg: Data, width: Int, height: Int) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }
}

public protocol ScreenSource: Sendable {
    func frame(display: Int, longEdge: Int, maximumBytes: Int) async throws -> ScreenFrame
    func text(display: Int) async throws -> String
}

public actor GuardedScreen: ScreenProviding {
    private let source: any ScreenSource
    private let now: @Sendable () -> ContinuousClock.Instant
    private let activity: @Sendable (Bool) -> Void
    private var inFlight = false
    private var lastStart: ContinuousClock.Instant?

    public init(
        source: any ScreenSource,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        activity: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.source = source
        self.now = now
        self.activity = activity
    }

    public func capture(display: Int, readText: Bool) async throws -> ScreenImageRecord {
        try begin()
        defer { finish() }
        let frame = try await source.frame(display: display, longEdge: ScreenLimits.longEdge, maximumBytes: ScreenLimits.maximumImageBytes)
        let text = readText ? Self.capped(try await source.text(display: display)) : nil
        return ScreenImageRecord(jpeg: frame.jpeg, width: frame.width, height: frame.height, display: display, text: text)
    }

    public func readText(display: Int) async throws -> String {
        try begin()
        defer { finish() }
        return Self.capped(try await source.text(display: display))
    }

    private func begin() throws {
        guard !inFlight else { throw DeviceProviderError.failed("A screen capture is already running on this Mac.") }
        let start = now()
        if let lastStart, lastStart.duration(to: start) < ScreenLimits.minimumInterval {
            throw DeviceProviderError.failed("The screen can be captured at most once every 3 seconds.")
        }
        inFlight = true
        lastStart = start
        activity(true)
    }

    private func finish() {
        inFlight = false
        activity(false)
    }

    private static func capped(_ text: String) -> String {
        String(text.prefix(ScreenLimits.maximumTextCharacters))
    }
}
