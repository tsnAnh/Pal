import Testing
@testable import PalDesign

@Suite("Catch-up notice window")
struct CatchUpNoticeTests {
    @Test("the notice appears after 150 ms, well before the silent window")
    func window() {
        #expect(LoadingPolicy.catchUpNoticeWindow == .milliseconds(150))
        #expect(LoadingPolicy.catchUpNoticeWindow < LoadingPolicy.silentWindow)
    }

    @Test("a wait that is still pending after the window reports the notice due")
    func slowPageShowsNotice() async {
        #expect(await LoadingPolicy.waited(LoadingPolicy.catchUpNoticeWindow))
    }

    @Test("a fresh page landing inside the window cancels the wait and shows no notice")
    func freshPageShowsNoNotice() async {
        let wait = Task { await LoadingPolicy.waited(LoadingPolicy.catchUpNoticeWindow) }
        try? await Task.sleep(for: .milliseconds(20))
        wait.cancel()
        #expect(await wait.value == false)
    }
}
