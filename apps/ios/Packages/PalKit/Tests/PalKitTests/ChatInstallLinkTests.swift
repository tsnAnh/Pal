import Foundation
import PalBotProfile
import PalProtocol
import Testing

@Suite("Chat install link")
struct ChatInstallLinkTests {
    private func parse(_ text: String, scheme: PalURLScheme = .release) -> ChatInstallLink? {
        URL(string: text).flatMap { ChatInstallLink(url: $0, scheme: scheme) }
    }

    @Test func eachBuildAcceptsOnlyItsOwnScheme() {
        #expect(parse("dev.tsnanh.hermes.bot.dev://chat/install-done", scheme: .development) == .installDone)
        #expect(parse("dev.tsnanh.hermes.bot://chat/install-done", scheme: .development) == nil)
        #expect(parse("dev.tsnanh.hermes.bot.dev://chat/install-done", scheme: .release) == nil)
    }

    @Test func acceptsTheExactInstallDoneLink() {
        #expect(parse("dev.tsnanh.hermes.bot://chat/install-done") == .installDone)
    }

    @Test func ignoresQueryAndFragment() {
        #expect(parse("dev.tsnanh.hermes.bot://chat/install-done?code=fake-token-do-not-use&state=x") == .installDone)
        #expect(parse("dev.tsnanh.hermes.bot://chat/install-done#fake-token-do-not-use") == .installDone)
    }

    @Test func rejectsOtherSchemesHostsAndPaths() {
        let rejected = [
            "https://chat/install-done",
            "dev.tsnanh.hermes://chat/install-done",
            "dev.tsnanh.hermes.bot://other/install-done",
            "dev.tsnanh.hermes.bot://chat/other",
            "dev.tsnanh.hermes.bot://chat/install-done/extra",
            "dev.tsnanh.hermes.bot://chat/install-done/",
            "dev.tsnanh.hermes.bot://chat",
            "dev.tsnanh.hermes.bot:///install-done",
            "dev.tsnanh.hermes.bot://UFAKE0000@chat/install-done",
            "dev.tsnanh.hermes.bot://chat:8080/install-done",
        ]
        for link in rejected { #expect(parse(link) == nil, "\(link)") }
    }
}
