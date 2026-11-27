import PalConnect
import PalProtocol
import Testing

@Suite("Discord page live state")
@MainActor
struct DiscordPageStateTests {
    private func page(_ adapter: ChatAdapterStatusWire?) async -> (DiscordSetupModel, FakeDiscord) {
        let fake = FakeDiscord(app: true, lists: [[studio]], existing: studioInstall(adapter))
        let wizard = discordWizard(fake)
        await wizard.load()
        return (wizard, fake)
    }

    private func notConnected(_ wizard: DiscordSetupModel) -> SetupStatus? {
        guard case .notConnected(let status) = wizard.stage else { return nil }
        return status
    }

    private func connectedTitle(_ wizard: DiscordSetupModel) -> String? {
        guard wizard.stage == .flow, wizard.flow.engine.isFinished,
              case .success(let title, _) = wizard.flow.engine.current.kind
        else { return nil }
        return title
    }

    @Test func aReadyRecordWithALiveAdapterSaysConnected() async {
        let (wizard, _) = await page(ChatAdapterStatusWire(state: .online))
        #expect(connectedTitle(wizard) == "Discord is connected")
    }

    @Test(arguments: [
        (ChatAdapterStatusWire(state: .notStarted), "Your Pal is not connected to Discord right now. Reconnect to try again."),
        (ChatAdapterStatusWire(state: .connecting), "Your Pal is still connecting to Discord. Reconnect to try again."),
        (
            ChatAdapterStatusWire(state: .failed, reason: .invalidToken),
            "Discord did not accept the Pal app token. Reset it on the Bot page of the Pal app, "
                + "paste the new one under Discord in Connected apps, then reconnect."
        ),
        (
            ChatAdapterStatusWire(state: .failed, reason: .missingIntent),
            "Message Content is switched off on the Bot page of the Pal app. Switch it on and save, then reconnect."
        ),
        (
            ChatAdapterStatusWire(state: .failed, reason: .missingPermission),
            "Pal cannot see #ada. Give the Pal role View Channel there, then reconnect."
        ),
        (ChatAdapterStatusWire(state: .failed, reason: .restartNeeded), "Restart Pal on your computer, then reconnect."),
        (
            ChatAdapterStatusWire(state: .failed, reason: .adapterOffline),
            "Your Pal is not connected to Discord right now. Reconnect to try again."
        ),
        (ChatAdapterStatusWire(state: .unknown), "Your Pal is not connected to Discord right now. Reconnect to try again."),
    ])
    func aReadyRecordWithoutALiveAdapterSaysWhyAndOffersReconnect(adapter: ChatAdapterStatusWire, sentence: String) async throws {
        let (wizard, fake) = await page(adapter)
        let status = try #require(notConnected(wizard))
        #expect(status.title == "Discord is not connected")
        #expect(status.reason == sentence)
        #expect(status.actionTitle == "Reconnect")
        #expect(await fake.installs.isEmpty)
    }

    @Test func aGatewayThatSendsNoLiveStateIsNotShownAsConnected() async throws {
        let (wizard, _) = await page(nil)
        let status = try #require(notConnected(wizard))
        #expect(status.code == "gateway_outdated")
        #expect(status.actionTitle == "Reconnect")
    }

    @Test func reconnectAsksTheGatewayForThatServerAndShowsConnected() async {
        let (wizard, fake) = await page(ChatAdapterStatusWire(state: .notStarted))
        await wizard.reconnect()
        #expect(await fake.reconnects == ["222"])
        #expect(connectedTitle(wizard) == "Discord is connected")
    }

    @Test func aReconnectThatStillFailsKeepsThePageWithTheNewReason() async throws {
        let (wizard, fake) = await page(ChatAdapterStatusWire(state: .notStarted))
        await fake.setReconnect(.success(studioInstall(ChatAdapterStatusWire(state: .failed, reason: .missingIntent))))
        await wizard.reconnect()
        #expect(try #require(notConnected(wizard)).code == "missing_intent")
        #expect(wizard.isReconnecting == false)
    }

    @Test func aReconnectTheGatewayRefusesStillOffersReconnect() async throws {
        let (wizard, fake) = await page(ChatAdapterStatusWire(state: .notStarted))
        await fake.setReconnect(.failure(SetupStatusError(SetupStatus(code: "offline", subject: "Discord"))))
        await wizard.reconnect()
        let status = try #require(notConnected(wizard))
        #expect(status.code == "offline")
        #expect(status.actionTitle == "Reconnect")
    }

    @Test func aFinishedInstallThatIsNotLiveDoesNotShowTheConnectedScreen() async throws {
        let offline = studioInstall(ChatAdapterStatusWire(state: .failed, reason: .adapterOffline))
        let wizard = discordWizard(FakeDiscord(app: true, lists: [[studio]], installResult: .success(.installed(offline))))
        await wizard.load()
        await wizard.flow.performPrimary()
        #expect(try #require(notConnected(wizard)).title == "Discord is not connected")
    }

    @Test(arguments: [
        ("restart_needed", "Your Pal needs a restart", "Restart Pal on your computer, then retry."),
        ("adapter_offline", "Discord did not connect", "Your Pal could not connect to Discord in time. Retry in a moment."),
    ])
    func aWizardThatCannotConnectEndsInAPlainSentenceWithRetry(reason: String, title: String, sentence: String) {
        let status = DiscordSetupPlan.failure(
            ChatSetupErrorWire(code: .installFailed, fix: .retry, reason: reason), server: studio, invite: nil
        )
        #expect(status.title == title)
        #expect(status.reason == sentence)
        #expect(status.actionTitle == "Retry")
    }
}
