import Foundation

public enum ClarifyAnswer {
    public static func compose(choices: [String], selection: Set<Int>, typed: String, multiSelect: Bool) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard multiSelect else { return text.isEmpty ? nil : text }
        let picked = selection.sorted()
        if text.isEmpty {
            return picked.isEmpty ? nil : picked.map { String($0 + 1) }.joined(separator: ",")
        }
        let labels = picked.compactMap { choices.indices.contains($0) ? choices[$0] : nil } + [text]
        guard let data = try? JSONEncoder().encode(labels) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    public static func wire(choices: [String], selection: Set<Int>, typed: String, multiSelect: Bool) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = selection.sorted().compactMap { choices.indices.contains($0) ? choices[$0] : nil }
        guard multiSelect else { return text.isEmpty ? labels.first : text }
        let all = text.isEmpty ? labels : labels + [text]
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
