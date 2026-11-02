import Foundation
import os
import Synchronization

public enum DiagnosticLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct DiagnosticEvent: Sendable, Equatable {
    public var level: DiagnosticLevel
    public var category: String
    public var message: String

    public init(level: DiagnosticLevel, category: String, message: String) {
        self.level = level
        self.category = category
        self.message = message
    }
}

public protocol DiagnosticSummarizing {
    var diagnosticSummary: String { get }
}

public struct Diagnostics: Sendable {
    public typealias Sink = @Sendable (DiagnosticEvent) -> Void

    private let sink: Sink

    public init(sink: @escaping Sink) {
        self.sink = sink
    }

    public static let silent = Diagnostics { _ in }

    public static func osLog(subsystem: String = "dev.tsnanh.hermes.bot") -> Diagnostics {
        let loggers = Mutex<[String: Logger]>([:])
        return Diagnostics { event in
            let logger = loggers.withLock { cache in
                if let existing = cache[event.category] { return existing }
                let created = Logger(subsystem: subsystem, category: event.category)
                cache[event.category] = created
                return created
            }
            switch event.level {
            case .debug: logger.debug("\(event.message, privacy: .public)")
            case .info: logger.info("\(event.message, privacy: .public)")
            case .warning: logger.warning("\(event.message, privacy: .public)")
            case .error: logger.error("\(event.message, privacy: .public)")
            }
        }
    }

    public func combined(with other: Diagnostics) -> Diagnostics {
        Diagnostics { event in
            self.sink(event)
            other.sink(event)
        }
    }

    public func log(_ level: DiagnosticLevel, _ category: String, _ message: String) {
        sink(DiagnosticEvent(level: level, category: category, message: message))
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public static func describe(_ error: any Error) -> String {
        if let summarizing = error as? any DiagnosticSummarizing { return summarizing.diagnosticSummary }
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            let label = mirror.children.first?.label
            return label.map { "\(type(of: error)).\($0)" } ?? "\(type(of: error)).\(error)"
        }
        let bridged = error as NSError
        return "\(type(of: error)) domain=\(bridged.domain) code=\(bridged.code)"
    }

    public static func describe(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "<url>" }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "<url>"
    }
}

public final class DiagnosticRecorder: Sendable {
    private let storage = Mutex<[DiagnosticEvent]>([])

    public init() {}

    public var diagnostics: Diagnostics {
        Diagnostics { event in
            self.storage.withLock { $0.append(event) }
        }
    }

    public var events: [DiagnosticEvent] {
        storage.withLock { $0 }
    }

    public var transcript: String {
        events.map { "[\($0.level.rawValue)] \($0.category): \($0.message)" }.joined(separator: "\n")
    }
}
