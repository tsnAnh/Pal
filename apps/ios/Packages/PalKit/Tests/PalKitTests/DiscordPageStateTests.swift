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

    private func access(_ id: String, _ name: String?, _ state: ChatChannelAccessState) -> ChatChannelAccessWire {
        ChatChannelAccessWire(channelId: id, name: name, access: state)
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

    private func checkedPage(
        _ adapter: ChatAdapterStatusWire = ChatAdapterStatusWire(state: .online),
        _ access: Result<[ChatChannelAccessWire], SetupStatusError>
    ) async -> (DiscordSetupModel, FakeDiscord) {
        let fake = FakeDiscord(app: true, lists: [[studio]], existing: studioInstall(adapter))
        await fake.setAccess(access)
        let wizard = discordWizard(fake)
        await wizard.load()
        await wizard.channelsChecked()
        return (wizard, fake)
    }

    @Test func loadingTheConnectedPageChecksThatServerAndSaysNothingWhenEveryChannelWorks() async {
        let (wizard, fake) = await checkedPage(.init(state: .online), .success([access("900", "ada", .ok)]))
        #expect(await fake.checks == ["222"])
        #expect(wizard.channelWarnings.isEmpty)
        #expect(connectedTitle(wizard) == "Discord is connected")
    }

    @Test(arguments: [
        (ChatChannelAccessState.cannotView, "Pal cannot see #ada. Give the Pal role View Channel there, then reconnect."),
        (
            ChatChannelAccessState.cannotSend,
            "Pal cannot send messages in #ada. Give the Pal role Send Messages there, then reconnect."
        ),
        (ChatChannelAccessState.unknown, "Pal could not check its permissions in #ada."),
    ])
    func aChannelThatDoesNotPassIsNamedInPlainWords(state: ChatChannelAccessState, sentence: String) async {
        let (wizard, _) = await checkedPage(.init(state: .online), .success([access("900", "ada", state)]))
        #expect(wizard.channelWarnings == [sentence])
        #expect(connectedTitle(wizard) == "Discord is connected")
    }

    @Test func everyChosenChannelThatFailsGetsItsOwnSentence() async {
        let found = [access("900", "ada", .ok), access("901", "ops", .cannotSend), access("902", nil, .cannotView)]
        let (wizard, _) = await checkedPage(.init(state: .online), .success(found))
        #expect(wizard.channelWarnings == [
            "Pal cannot send messages in #ops. Give the Pal role Send Messages there, then reconnect.",
            "Pal cannot see its channel. Give the Pal role View Channel there, then reconnect.",
        ])
    }

    @Test func aCheckThatFailsReadsAsUncheckedWithoutItsError() async {
        let refused = SetupStatusError(SetupStatus(code: "provider_failed", subject: "Discord"))
        let (wizard, _) = await checkedPage(.init(state: .online), .failure(refused))
        #expect(wizard.channelWarnings == ["Pal could not check its permissions in Discord."])
        #expect(connectedTitle(wizard) == "Discord is connected")
    }

    @Test func aSilentCheckNeverHoldsThePageAndEndsUnchecked() async {
        let fake = FakeDiscord(app: true, lists: [[studio]], existing: wizardInstalled)
        await fake.silence(["channelAccess"])
        let wizard = discordWizard(fake)
        await wizard.load()
        #expect(connectedTitle(wizard) == "Discord is connected")
        #expect(wizard.channelWarnings.isEmpty)
        await wizard.channelsChecked()
        #expect(wizard.channelWarnings == ["Pal could not check its permissions in Discord."])
    }

    @Test func theNotConnectedPageDoesNotRepeatItsOwnSentence() async {
        let hidden = ChatAdapterStatusWire(state: .failed, reason: .missingPermission)
        let found = [access("900", "ada", .cannotView), access("901", "ops", .cannotSend)]
        let (wizard, _) = await checkedPage(hidden, .success(found))
        #expect(wizard.channelWarnings == [
            "Pal cannot send messages in #ops. Give the Pal role Send Messages there, then reconnect."
        ])
    }

    @Test func aGatewayWithoutLiveStateIsNotAskedAboutChannels() async {
        let fake = FakeDiscord(app: true, lists: [[studio]], existing: studioInstall(nil))
        let wizard = discordWizard(fake)
        await wizard.load()
        await wizard.channelsChecked()
        #expect(await fake.checks.isEmpty)
    }

    @Test func reconnectingFromTheConnectedPageChecksTheChannelsAgain() async {
        let (wizard, fake) = await checkedPage(.init(state: .online), .success([access("900", "ada", .cannotView)]))
        await fake.setAccess(.success([access("900", "ada", .ok)]))
        await wizard.reconnect()
        await wizard.channelsChecked()
        #expect(await fake.reconnects == ["222"])
        #expect(await fake.checks == ["222", "222"])
        #expect(wizard.channelWarnings.isEmpty)
        #expect(connectedTitle(wizard) == "Discord is connected")
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
