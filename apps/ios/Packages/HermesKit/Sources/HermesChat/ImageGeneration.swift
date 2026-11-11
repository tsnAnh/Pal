import Foundation
import HermesProtocol

public enum ImageGeneration: Sendable, Hashable {
    public enum Shape: Sendable, Hashable {
        case landscape
        case square
        case portrait

        public init(hint: String?) {
            switch hint?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "square": self = .square
            case "portrait": self = .portrait
            default: self = .landscape
            }
        }

        public var ratio: Double {
            switch self {
            case .landscape: 16.0 / 9.0
            case .square: 1
            case .portrait: 9.0 / 16.0
            }
        }
    }

    case generating(prompt: String?, shape: Shape)
    case ready(ImageReference)
    case failed(reason: String)

    public static let toolName = "image_generate"
    public static let stoppedReason = "Image creation stopped before it finished."
    public static let genericFailure = "The image couldn't be created."

    public static func resolve(
        status: ToolCall.Status,
        prompt: String?,
        aspectRatio: String?,
        result: JSONValue?
    ) -> ImageGeneration {
        switch status {
        case .running:
            return .generating(prompt: summary(of: prompt), shape: Shape(hint: aspectRatio))
        case .finished:
            guard let record = record(from: result) else { return .failed(reason: stoppedReason) }
            return outcome(of: record)
        }
    }

    public static func summary(of prompt: String?) -> String? {
        guard let flattened = prompt?.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces), !flattened.isEmpty
        else { return nil }
        return flattened.count > 160 ? String(flattened.prefix(160)) + "…" : flattened
    }

    static func record(from value: JSONValue?) -> [String: JSONValue]? {
        switch value {
        case .object(let object):
            return object
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return parsed.objectValue
        default:
            return nil
        }
    }

    private static func outcome(of record: [String: JSONValue]) -> ImageGeneration {
        if record["success"]?.boolValue != false, let reference = reference(in: record) {
            return .ready(reference)
        }
        return .failed(reason: reason(in: record))
    }

    private static func reference(in record: [String: JSONValue]) -> ImageReference? {
        for key in ["host_image", "image"] {
            if let raw = record[key]?.stringValue, let reference = reference(forSource: raw) { return reference }
        }
        return nil
    }

    static func reference(forSource raw: String) -> ImageReference? {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains("\u{0}") else { return nil }
        let lowered = source.lowercased()
        if lowered.hasPrefix("data:image/") {
            guard let marker = source.range(of: ";base64,"),
                  let data = Data(base64Encoded: String(source[marker.upperBound...])), !data.isEmpty
            else { return nil }
            return ImageReference(source: .inline(data))
        }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: source), url.host() != nil else { return nil }
            return ImageReference(source: .remote(url))
        }
        guard !source.contains("://") else { return nil }
        return ImageReference(source: .hostPath(source))
    }

    private static func reason(in record: [String: JSONValue]) -> String {
        for key in ["error", "message"] {
            if let text = record[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.count > 240 ? String(text.prefix(240)) + "…" : text
            }
        }
        return genericFailure
    }
}
