import Foundation

public enum MediaAccessibility {
    public static let openHint = "Double tap to open"

    public static func label(
        kind: String, name: String, duration: TimeInterval? = nil, pages: String? = nil, size: String? = nil,
        position: (index: Int, total: Int)? = nil
    ) -> String {
        let spokenDuration = duration.flatMap { $0.isFinite && $0 > 0 ? MediaDuration.spoken($0) : nil }
        let spokenPosition = position.flatMap { $0.total > 1 ? "\($0.index + 1) of \($0.total)" : nil }
        return [kind, name, spokenDuration, pages, size, spokenPosition].compactMap { $0 }.joined(separator: ", ")
    }

    public static func video(name: String, duration: TimeInterval?, position: (index: Int, total: Int)? = nil) -> String {
        label(kind: "Video", name: name, duration: duration, position: position)
    }

    public static func tooLarge(kind: String, name: String, size: Int?) -> String {
        label(kind: kind, name: name, size: size.map(MediaSize.label)) + ", " + MediaStateText.tooLargeSuffix
    }

    public static func failed(kind: String, name: String, reason: String) -> String {
        label(kind: kind, name: name) + ", " + reason
    }
}

public enum MediaStateText {
    public static let tooLargeSuffix = "too large to preview"

    public static func tooLarge(size: Int?, playable: Bool) -> String {
        let reason = playable ? "Too large to play here" : "Too large to preview"
        return size.map { "\(MediaSize.label($0)) · \(reason)" } ?? reason
    }
}

extension MediaDuration {
    public static func spoken(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 seconds" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds.rounded()) ?? MediaDuration.label(seconds)
    }
}
