import Foundation

public struct JSONPresentation: Sendable, Equatable {
    public var pretty: String
    public var summary: String

    public init(pretty: String, summary: String) {
        self.pretty = pretty
        self.summary = summary
    }
}

public enum JSONPretty {
    static let presentLimit = 1_000_000
    static let classifyLimit = 512 * 1024

    public static func present(_ source: String) -> JSONPresentation? {
        let bytes = Array(source.utf8)
        guard !bytes.isEmpty, bytes.count <= presentLimit,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
        else { return nil }
        return JSONPresentation(pretty: String(decoding: indent(bytes), as: UTF8.self), summary: summary(of: object))
    }

    static func isValidContainer(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= 2, trimmed.utf8.count <= classifyLimit,
              let first = trimmed.utf8.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
        else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil
    }

    private static func summary(of object: Any) -> String {
        if let dictionary = object as? [String: Any] {
            return "{ \(dictionary.count) \(dictionary.count == 1 ? "key" : "keys") }"
        }
        if let array = object as? [Any] {
            return "[ \(array.count) \(array.count == 1 ? "item" : "items") ]"
        }
        if object is String { return "string" }
        if object is NSNull { return "null" }
        return "value"
    }

    private static func indent(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + bytes.count / 4)
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0

        func newline() {
            output.append(0x0A)
            output.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                index += 1
                continue
            }
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                break
            case 0x22:
                inString = true
                output.append(byte)
            case 0x7B, 0x5B:
                let closer: UInt8 = byte == 0x7B ? 0x7D : 0x5D
                var lookahead = index + 1
                while lookahead < bytes.count, isSpace(bytes[lookahead]) { lookahead += 1 }
                if lookahead < bytes.count, bytes[lookahead] == closer {
                    output.append(byte)
                    output.append(closer)
                    index = lookahead
                } else {
                    output.append(byte)
                    depth += 1
                    newline()
                }
            case 0x7D, 0x5D:
                depth = max(0, depth - 1)
                newline()
                output.append(byte)
            case 0x2C:
                output.append(byte)
                newline()
            case 0x3A:
                output.append(byte)
                output.append(0x20)
            default:
                output.append(byte)
            }
            index += 1
        }
        return output
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
