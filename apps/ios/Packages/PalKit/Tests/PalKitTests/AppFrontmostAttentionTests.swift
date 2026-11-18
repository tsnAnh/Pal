import PalAuth
import PalClient
import Testing

@Suite("Attention follows the frontmost app")
struct AppFrontmostAttentionTests {
    private func presence() -> ReachPresence {
        ReachPresence(identity: DeviceIdentity(deviceID: "0B7F3F2E-5A4B-4E5E-9D1C-1F2E3D4C5B6A", formFactor: .mac, appVersion: "0.1.0 (7)"))
    }

    @Test func anActiveSceneInAnAppThatIsNotFrontmostIsBackground() async {
        let presence = presence()
        await presence.setAttention(.foreground)
        await presence.setAppFrontmost(false)
        #expect(await presence.currentAttention == .background)
        await presence.setAppFrontmost(true)
        #expect(await presence.currentAttention == .foreground)
    }

    @Test func aBackgroundSceneStaysBackgroundWhenTheAppBecomesFrontmost() async {
        let presence = presence()
        await presence.setAttention(.background)
        await presence.setAppFrontmost(false)
        await presence.setAppFrontmost(true)
        #expect(await presence.currentAttention == .background)
    }

    @Test func offersFollowTheSceneNotTheFrontmostApp() async {
        let presence = presence()
        await presence.setAppFrontmost(false)
        #expect(await presence.canPresentOffers)
    }
}
