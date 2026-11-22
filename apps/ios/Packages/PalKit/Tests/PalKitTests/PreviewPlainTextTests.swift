import PalRoster
import Testing

@Suite("Roster previews read as plain text")
struct PreviewPlainTextTests {
    private func shown(_ preview: String) -> String {
        PreviewClassifier.classify(preview).text
    }

    @Test func emphasisAndCodeMarkersAreRemoved() {
        #expect(shown("**Weekly report** is ready") == "Weekly report is ready")
        #expect(shown("Cron `faker-kit-babysit` failed with `Gateway") == "Cron faker-kit-babysit failed with Gateway")
        #expect(shown("~~old~~ new and *soft* words") == "old new and soft words")
    }

    @Test func aPreviewCutInsideAMarkerLeavesNoStrayMarker() {
        #expect(shown("**Inside the SkinSort group, t") == "Inside the SkinSort group, t")
        #expect(shown("See [PR #9](https://github.com/o/r/pull/9) and [the do") == "See PR #9 and the do")
    }

    @Test func blockMarkersAtTheStartAreRemoved() {
        #expect(shown("# Daily digest") == "Daily digest")
        #expect(shown("- first item") == "first item")
        #expect(shown("> quoted reply") == "quoted reply")
        #expect(shown("1. step one") == "step one")
    }

    @Test func wordsThatOnlyLookLikeMarkdownStayIntact() {
        #expect(shown("rename snake_case_name to 2*3 grid") == "rename snake_case_name to 2*3 grid")
        #expect(shown("price is $5 * 2") == "price is $5 * 2")
    }

    @Test func aBotSenderPrefixKeepsItsNameAndLosesTheBodyMarkers() {
        let preview = PreviewClassifier.classify(
            "Message from 🤖 Manager (@manager): **Merged** `#275`",
            senders: [PreviewSender(name: "manager", displayName: "Manager")]
        )
        #expect(preview.text == "Message from Manager: Merged #275")
    }
}
