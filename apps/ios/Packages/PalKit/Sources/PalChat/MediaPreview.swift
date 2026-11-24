import Foundation

public struct MediaMetadata: Sendable, Equatable {
    public var size: Int?
    public var duration: TimeInterval?
    public var width: Int?
    public var height: Int?

    public init(size: Int? = nil, duration: TimeInterval? = nil, width: Int? = nil, height: Int? = nil) {
        self.size = size
        self.duration = duration
        self.width = width
        self.height = height
    }
}

public enum MediaPreviewAnswer: Sendable, Equatable {
    case poster(Data, MediaMetadata)
    case unavailable(reason: String, MediaMetadata)
}

public struct MediaChunk: Sendable, Equatable {
    public let data: Data
    public let offset: Int
    public let total: Int

    public init(data: Data, offset: Int, total: Int) {
        self.data = data
        self.offset = offset
        self.total = total
    }
}

public protocol MediaAssetSource: Sendable {
    func preview(_ reference: MediaReference) async throws -> MediaPreviewAnswer
    func chunk(_ reference: MediaReference, offset: Int, length: Int) async throws -> MediaChunk
}

public struct MediaPreview: Sendable, Equatable {
    public let poster: Data?
    public let duration: TimeInterval?
    public let size: Int?
    public let width: Int?
    public let height: Int?
    public let pageCount: Int?

    public init(
        poster: Data?, duration: TimeInterval? = nil, size: Int? = nil, width: Int? = nil, height: Int? = nil,
        pageCount: Int? = nil
    ) {
        self.poster = poster
        self.duration = duration
        self.size = size
        self.width = width
        self.height = height
        self.pageCount = pageCount
    }

    public init(poster: Data?, metadata: MediaMetadata) {
        self.init(poster: poster, duration: metadata.duration, size: metadata.size, width: metadata.width, height: metadata.height)
    }
}

public enum MediaPreviewState: Sendable, Equatable {
    case idle
    case loading
    case ready(MediaPreview)
    case tooLarge(size: Int?)
    case failed(reason: String, retryable: Bool)
}

public struct MediaPreviewLoader: Sendable, Equatable {
    public private(set) var state: MediaPreviewState

    public init(state: MediaPreviewState = .idle) {
        self.state = state
    }

    public var isLoading: Bool { state == .loading }

    public mutating func start() -> Bool {
        guard state == .idle else { return false }
        state = .loading
        return true
    }

    public mutating func retry() -> Bool {
        guard case .failed(_, true) = state else { return false }
        state = .loading
        return true
    }

    public mutating func finish(_ outcome: MediaPreviewState) {
        guard state == .loading else { return }
        switch outcome {
        case .ready, .tooLarge, .failed: state = outcome
        case .idle, .loading: break
        }
    }

    public mutating func cancel() {
        if state == .loading { state = .idle }
    }

    public func displayed(cached: MediaPreview?) -> MediaPreviewState {
        switch state {
        case .idle, .loading: cached.map(MediaPreviewState.ready) ?? state
        case .ready, .tooLarge, .failed: state
        }
    }
}

public struct MediaFailure: Error, Sendable, Equatable {
    public let message: String
    public let retryable: Bool

    public init(message: String, retryable: Bool) {
        self.message = message
        self.retryable = retryable
    }

    public init(describing error: Error) {
        switch error as? MediaTransferError {
        case .tooLarge(let size):
            self.init(message: "Too large to play here (\(MediaSize.label(size)))", retryable: false)
        case .truncated:
            self.init(message: "The download was cut short", retryable: true)
        case .unwritable:
            self.init(message: "There is no room to keep this file", retryable: false)
        case nil:
            let failure = FileLoadFailure(describing: error, limitBytes: MediaLimits.downloadBytes)
            self.init(message: failure.message, retryable: failure.isTransient)
        }
    }
}

public enum MediaSize {
    public static func label(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public enum MediaDuration {
    public static func label(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let tail = String(format: "%02d", total % 60)
        guard total >= 3600 else { return "\(total / 60):\(tail)" }
        return "\(total / 3600):" + String(format: "%02d", total % 3600 / 60) + ":" + tail
    }
}
