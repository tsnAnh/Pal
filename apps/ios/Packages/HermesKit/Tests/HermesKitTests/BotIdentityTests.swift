import HermesRoster
import Testing

@Suite("Bot identity")
struct BotIdentityTests {
    @Test func asciiNamesSlugLikeDesktop() {
        #expect(BotIdentity.slug(from: "Inbox Triage") == "inbox-triage")
        #expect(BotIdentity.slug(from: "  My  Bot!! ") == "my-bot")
        #expect(BotIdentity.slug(from: "foo_bar") == "foo_bar")
        #expect(BotIdentity.slug(from: "a- b") == "a--b")
    }

    @Test func cjkNamesBecomeDeterministicCodePointTokens() {
        #expect(BotIdentity.slug(from: "小助手") == "u5c0f-u52a9-u624b")
        #expect(BotIdentity.slug(from: "test机器人") == "test-u673a-u5668-u4eba")
        #expect(BotIdentity.slug(from: "u5c0f-u52a9-u624b") == "u5c0f-u52a9-u624b")
        #expect(BotIdentity.slug(from: "한글") == "ud55c-uae00")
        #expect(BotIdentity.slug(from: "ガ") != BotIdentity.slug(from: "カ"))
    }

    @Test func accentedLatinFoldsToBaseLetters() {
        #expect(BotIdentity.slug(from: "Café Résumé") == "cafe-resume")
        #expect(BotIdentity.slug(from: "chó UA") == "cho-ua")
        #expect(BotIdentity.slug(from: "chó hóng hớt") == "cho-hong-hot")
        #expect(BotIdentity.slug(from: "chó Định") == "cho--u110-inh")
        let decomposed = "Cafe\u{301}"
        #expect(BotIdentity.slug(from: decomposed) == "cafe")
    }

    @Test func nameWithoutLettersOrDigitsHasNoSlug() {
        #expect(BotIdentity.slug(from: "🤖") == "")
        #expect(BotIdentity.slug(from: "   ") == "")
        #expect(BotIdentity.slug(from: "") == "")
        #expect(!BotIdentity(entered: "🤖").isValid)
        #expect(!BotIdentity(entered: "   ").isValid)
    }

    @Test func emojiAroundLettersKeepsTheLetters() {
        #expect(BotIdentity.slug(from: "🤖 Robo 🤖") == "robo")
        #expect(BotIdentity(entered: "🤖 Robo").isValid)
    }

    @Test func slugNeverSplitsATokenAtTheSixtyFourCharacterCap() {
        let long = BotIdentity.slug(from: String(repeating: "小助手", count: 7))
        #expect(long == "u5c0f-u52a9-u624b-u5c0f-u52a9-u624b-u5c0f-u52a9-u624b-u5c0f")
        #expect(long.count <= 64)
        #expect(BotIdentity(entered: String(repeating: "a", count: 90)).slug.count == 64)
    }

    @Test func validityMatchesTheServersProfileIdRules() {
        #expect(BotIdentity(entered: "Nova Helper").isValid)
        #expect(!BotIdentity(entered: "_hidden").isValid)
        for reserved in ["Hermes", "Default", "test", "root", "sudo", "tmp"] {
            #expect(!BotIdentity(entered: reserved).isValid, "\(reserved) is reserved by the gateway")
        }
    }

    @Test func displayNameKeepsWhatTheUserTypedTrimmed() {
        let identity = BotIdentity(entered: "  chó UA \n")
        #expect(identity.displayName == "chó UA")
        #expect(identity.slug == "cho-ua")
    }
}
