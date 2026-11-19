import Foundation

public struct ReactionEmoji: Sendable, Hashable, Identifiable {
    public let symbol: String
    public let keywords: [String]
    public var id: String { symbol }

    public init(_ symbol: String, _ keywords: String...) {
        self.symbol = symbol
        self.keywords = keywords
    }
}

public enum ReactionCatalog {
    public static let quick = ["👍", "👎", "❤️", "😂", "🎉", "😮", "🔥", "👀", "🙏", "😢", "💯"]

    public static let all: [ReactionEmoji] = [
        ReactionEmoji("👍", "thumbs up", "like", "yes", "ok"),
        ReactionEmoji("👎", "thumbs down", "dislike", "no"),
        ReactionEmoji("❤️", "heart", "love", "red"),
        ReactionEmoji("😂", "laugh", "joy", "funny", "lol"),
        ReactionEmoji("🎉", "party", "tada", "celebrate", "congrats"),
        ReactionEmoji("😮", "wow", "surprised", "open mouth"),
        ReactionEmoji("🔥", "fire", "hot", "lit"),
        ReactionEmoji("👀", "eyes", "look", "watching"),
        ReactionEmoji("🙏", "pray", "thanks", "please", "folded hands"),
        ReactionEmoji("😢", "cry", "sad", "tear"),
        ReactionEmoji("💯", "hundred", "perfect", "100"),
        ReactionEmoji("👏", "clap", "applause", "bravo"),
        ReactionEmoji("🤔", "thinking", "hmm", "think"),
        ReactionEmoji("😅", "sweat smile", "nervous", "relief"),
        ReactionEmoji("😍", "heart eyes", "love", "adore"),
        ReactionEmoji("🥳", "partying face", "party", "birthday"),
        ReactionEmoji("✅", "check", "done", "tick", "yes"),
        ReactionEmoji("🙌", "raised hands", "praise", "hooray"),
        ReactionEmoji("💪", "muscle", "strong", "flex"),
        ReactionEmoji("😎", "cool", "sunglasses"),
        ReactionEmoji("🤝", "handshake", "deal", "agree"),
        ReactionEmoji("😬", "grimace", "awkward", "yikes"),
        ReactionEmoji("🚀", "rocket", "launch", "ship"),
        ReactionEmoji("😴", "sleep", "tired", "zzz"),
        ReactionEmoji("🙈", "see no evil", "monkey", "shy"),
        ReactionEmoji("👌", "ok hand", "perfect", "fine"),
        ReactionEmoji("😭", "sob", "crying", "loud cry"),
        ReactionEmoji("🤯", "mind blown", "exploding head", "shock"),
        ReactionEmoji("💡", "idea", "light bulb", "bulb"),
    ]

    public static func search(_ query: String) -> [ReactionEmoji] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            entry.symbol == needle || entry.keywords.contains { $0.contains(needle) }
        }
    }
}
