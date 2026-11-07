import HermesRoster
import Testing

@Suite("Preview classification")
struct PreviewClassifierTests {
    private func fromBot(_ preview: String?) -> String? {
        if case .fromBot(let handle) = PreviewClassifier.kind(of: preview) { handle } else { nil }
    }

    @Test func plainPreviewIsNotABotMessage() {
        #expect(fromBot("Can you check the vault sync?") == nil)
    }

    @Test func currentRobotPrefixAndLegacyAgentPrefixAreParsed() {
        #expect(fromBot("Message from 🤖 manager (@manager): Learn-share: skill installed") == "manager")
        #expect(fromBot("Message from agent 'researcher': here is the paper") == "researcher")
    }

    @Test func primaryProfileReadsAsHermesNeverDefault() {
        #expect(fromBot("Message from agent 'default': deploy is green") == "hermes")
        #expect(fromBot("Message from agent 'ops': deploy is green") == "ops")
    }

    @Test func emptyOrAbsentPreviewIsNotABotMessage() {
        #expect(fromBot("") == nil)
        #expect(fromBot("   \n") == nil)
        #expect(fromBot(nil) == nil)
    }

    @Test func prefixMatchingIsCaseInsensitiveAndAnchored() {
        #expect(fromBot("message from AGENT 'Ops': x") == "ops")
        #expect(fromBot("Re: Message from agent 'ops': x") == nil)
    }

    private let roster = [
        PreviewSender(name: "cho-ua", displayName: "chó UA"),
        PreviewSender(name: "default", displayName: "chó grok bot"),
    ]

    @Test func botToBotPreviewShowsTheSendersDisplayName() {
        let result = PreviewClassifier.classify(
            "Message from 🤖 chó UA (@cho-ua): Anh CHỐT mới: 6 ảnh mỗi bộ", senders: roster
        )
        #expect(result.kind == .fromBot(handle: "cho-ua"))
        #expect(result.text == "Message from chó UA: Anh CHỐT mới: 6 ảnh mỗi bộ")
    }

    @Test func senderNameComesFromTheRosterWhenKnown() {
        let result = PreviewClassifier.classify("Message from 🤖 old name (@cho-ua): hi", senders: roster)
        #expect(result.text == "Message from chó UA: hi")
    }

    @Test func unknownSenderKeepsTheNameTheMessageCarried() {
        let result = PreviewClassifier.classify("Message from 🤖 Maia Prime (@maia): ping", senders: roster)
        #expect(result.kind == .fromBot(handle: "maia"))
        #expect(result.text == "Message from Maia Prime: ping")
    }

    @Test func legacyAgentFormResolvesThePrimaryAliasToItsDisplayName() {
        let result = PreviewClassifier.classify("Message from agent 'default': deploy is green", senders: roster)
        #expect(result.kind == .fromBot(handle: "hermes"))
        #expect(result.text == "Message from chó grok bot: deploy is green")
        let hermes = PreviewClassifier.classify("Message from 🤖 Hermes (@hermes): up", senders: roster)
        #expect(hermes.text == "Message from chó grok bot: up")
    }

    @Test func aRealHermesProfileKeepsItsOwnHandle() {
        let senders = roster + [PreviewSender(name: "hermes", displayName: "Hermes Two")]
        let result = PreviewClassifier.classify("Message from 🤖 x (@hermes): up", senders: senders)
        #expect(result.text == "Message from Hermes Two: up")
    }

    @Test func plainPreviewIsReturnedUnchanged() {
        let result = PreviewClassifier.classify("Đã giao làm 12 ảnh: bộ A pastel sáng", senders: roster)
        #expect(result.kind == .plain)
        #expect(result.text == "Đã giao làm 12 ảnh: bộ A pastel sáng")
        #expect(PreviewClassifier.classify(nil).text == "")
    }

    @Test func emptyBodyFallsBackToAnEllipsis() {
        let result = PreviewClassifier.classify("Message from agent 'ops':", senders: roster)
        #expect(result.text == "Message from ops: …")
    }
}
