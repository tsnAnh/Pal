import Foundation
import PalConnect
import PalProtocol
import Testing

private func record(
    _ connector: String, step: String, saved: [String] = [], device: String? = "iphone", at time: Double = 10
) -> JSONValue {
    [
        "connector": .string(connector), "bot": .null, "step_id": .string(step), "completed": .array(saved.map(JSONValue.string)),
        "device": device.map(JSONValue.string) ?? JSONValue.null, "updated_at": .double(time),
    ]
}

private func gateway(_ records: [JSONValue]) -> CustomRPC {
    CustomRPC([
        "connectors.setup.progress.get": { params in
            let wanted = params["connector"]?.stringValue
            return ["records": .array(records.filter { wanted == nil || $0["connector"]?.stringValue == wanted })]
        },
        "connectors.setup.progress.set": { _ in ["record": .null] },
    ])
}

private func app(_ slug: String, method: PalCatalogEntry.Method, status: PalCatalogEntry.Status = .needsSetup, guide: Bool = true) -> ConnectApp {
    let steps = [SetupStep(id: "token", kind: .paste, title: "Paste", fields: [SetupField(id: "token", label: "Token")])]
    let entry = PalCatalogEntry(
        slug: slug, name: slug.capitalized, category: "Tools", method: method, verified: true, status: status,
        setupGuide: guide ? SetupGuide(steps: steps) : nil
    )
    return ConnectApp(
        id: slug, name: entry.name, summary: "", category: "Tools", source: .catalog(entry),
        state: status == .connected ? .connected : .needsSetup
    )
}

@Suite("Setup progress on the gateway")
@MainActor
struct SetupProgressSyncTests {
    @Test func theRecordDecodesAndATypeOfDeviceThisAppDoesNotKnowIsDropped() throws {
        let known = try record("discord", step: "invite", saved: ["token"], device: "ipad").decoded(as: SetupProgressRecord.self)
        #expect(known == SetupProgressRecord(connector: "discord", stepID: "invite", completed: ["token"], device: .ipad, updatedAt: 10))
        let unknown = try record("discord", step: "invite", device: "watch").decoded(as: SetupProgressRecord.self)
        #expect(unknown.device == nil && unknown.stepID == "invite")
    }

    @Test func savingSendsStepIdsAndTheKindOfDeviceOnly() async throws {
        let rpc = gateway([])
        let store = GatewayStepFlowProgressStore(service: customService(rpc), device: .iphone)
        await store.save(StepFlowProgress(flowID: "owner-setup-google-workspace", stepID: "client", saved: ["client_id"]))
        let sent = try #require(rpc.params("connectors.setup.progress.set").first)
        #expect(sent["connector"]?.stringValue == "owner-setup-google-workspace" && sent["step_id"]?.stringValue == "client")
        #expect(sent["completed"]?.arrayValue?.compactMap(\.stringValue) == ["client_id"])
        #expect(sent["device"]?.stringValue == "iphone" && sent["finished"]?.boolValue == false)
        #expect(Set((sent.objectValue ?? [:]).keys) == ["connector", "step_id", "completed", "device", "finished"])
    }

    @Test func clearingMarksTheRecordFinished() async throws {
        let rpc = gateway([])
        await GatewayStepFlowProgressStore(service: customService(rpc), device: .mac).clear(flowID: "discord")
        let sent = try #require(rpc.params("connectors.setup.progress.set").first)
        #expect(sent["connector"]?.stringValue == "discord" && sent["finished"]?.boolValue == true && sent["device"]?.stringValue == "mac")
    }

    @Test func loadingNamesTheOtherDeviceButNotThisOne() async {
        let rpc = gateway([record("discord", step: "intents", saved: ["token"], device: "iphone")])
        let fromPhone = await GatewayStepFlowProgressStore(service: customService(rpc), device: .mac).load(flowID: "discord")
        #expect(fromPhone == StepFlowProgress(flowID: "discord", stepID: "intents", saved: ["token"], continuedFrom: .iphone))
        let here = await GatewayStepFlowProgressStore(service: customService(rpc), device: .iphone).load(flowID: "discord")
        #expect(here?.continuedFrom == nil && here?.stepID == "intents")
        #expect(await GatewayStepFlowProgressStore(service: customService(rpc), device: .mac).load(flowID: "owner-setup-github") == nil)
    }

    @Test func progressThatClaimsAValueTheGatewayNoLongerHasIsIgnored() async {
        let rpc = gateway([record("discord", step: "access", saved: ["token"])])
        let stale = GatewayStepFlowProgressStore(service: customService(rpc), device: .mac, gatewaySaved: [])
        #expect(await stale.load(flowID: "discord") == nil)
        let current = GatewayStepFlowProgressStore(service: customService(rpc), device: .mac, gatewaySaved: ["token"])
        #expect(await current.load(flowID: "discord")?.stepID == "access")
    }

    @Test func aGatewayThatCannotAnswerStartsTheFlowFromTheTopInsteadOfFailingIt() async {
        let rpc = CustomRPC([:])
        let store = GatewayStepFlowProgressStore(service: customService(rpc), device: .mac)
        #expect(await store.load(flowID: "discord") == nil)
        await store.save(StepFlowProgress(flowID: "discord", stepID: "token"))
        await store.clear(flowID: "discord")
        #expect(rpc.methods() == ["connectors.setup.progress.get", "connectors.setup.progress.set", "connectors.setup.progress.set"])
    }

    @Test func aFlowRestoresTheSavedStepAndSaysWhichDeviceMovedIt() async throws {
        let rpc = gateway([record("discord", step: "intents", saved: ["token"], device: "iphone")])
        let engine = try #require(DiscordFlow.engine(resume: nil))
        let flow = StepFlowModel(
            engine: engine, store: GatewayStepFlowProgressStore(service: customService(rpc), device: .mac, gatewaySaved: ["token"])
        )
        await flow.start()
        let restored = flow.engine
        #expect(restored.current.id == DiscordFlow.StepID.intents && restored.saved == ["token"])
        let continuation = flow.continuation
        #expect(continuation == SetupContinuation(device: .iphone, stepID: DiscordFlow.StepID.intents, doneSteps: 2))
        #expect(continuation?.title == "Continued from your iPhone" && continuation?.detail == "Steps 1 and 2 are already done")
    }

    @Test func aFlowBeganOnThisDeviceRestoresWithoutAnnouncingAContinuation() async throws {
        let rpc = gateway([record("discord", step: "intents", saved: ["token"], device: "mac")])
        let engine = try #require(DiscordFlow.engine(resume: nil))
        let flow = StepFlowModel(engine: engine, store: GatewayStepFlowProgressStore(service: customService(rpc), device: .mac))
        await flow.start()
        #expect(flow.engine.current.id == DiscordFlow.StepID.intents)
        #expect(flow.continuation == nil)
    }

    @Test func advancingSavesTheNewStepAndFinishingClearsIt() async throws {
        let rpc = gateway([])
        let engine = try #require(DiscordFlow.engine(resume: nil))
        let flow = StepFlowModel(engine: engine, store: GatewayStepFlowProgressStore(service: customService(rpc), device: .ipad))
        await flow.start()
        await flow.performPrimary()
        let sent = try #require(rpc.params("connectors.setup.progress.set").last)
        #expect(sent["step_id"]?.stringValue == DiscordFlow.StepID.token && sent["device"]?.stringValue == "ipad")
        #expect(sent["finished"]?.boolValue == false)
    }

    @Test func theContinuationNeedsAnotherDeviceAndAStepAlreadyDone() {
        #expect(SetupContinuation(device: nil, stepID: "client", doneSteps: 2) == nil)
        #expect(SetupContinuation(device: .mac, stepID: "client", doneSteps: 0) == nil)
        #expect(SetupContinuation(device: .mac, stepID: "token", doneSteps: 1)?.detail == "Step 1 is already done")
        #expect(SetupContinuation(device: .ipad, stepID: "client", doneSteps: 4)?.detail == "Steps 1 to 4 are already done")
    }

    @Test func theListOffersTheNewestSetupAnotherDeviceStartedAndSkipsTheRest() {
        let apps = [
            app("google-workspace", method: .oauthClient), app("github", method: .apiKey), app("discord", method: .botTokenStdio),
            app("figma", method: .oauthClient, status: .connected),
        ]
        let records = [
            SetupProgressRecord(connector: "owner-setup-github", stepID: "token", device: .iphone, updatedAt: 5),
            SetupProgressRecord(connector: "owner-setup-google-workspace", stepID: "client", device: .iphone, updatedAt: 9),
            SetupProgressRecord(connector: "discord", stepID: "token", device: .mac, updatedAt: 20),
            SetupProgressRecord(connector: "owner-setup-figma", stepID: "client", device: .iphone, updatedAt: 30),
            SetupProgressRecord(connector: "owner-setup-unknown", stepID: "client", device: .iphone, updatedAt: 40),
        ]
        let offer = SetupResume.offer(records: records, apps: apps, on: .mac)
        #expect(offer == SetupResumeOffer(appID: "google-workspace", appName: "Google-Workspace", device: .iphone))
        #expect(offer?.title == "Continue Google-Workspace" && offer?.detail == "Started on your iPhone")
        #expect(SetupResume.offer(records: records, apps: apps, on: .iphone)?.appID == "discord")
        #expect(SetupResume.offer(records: [], apps: apps, on: .mac) == nil)
    }

    @Test func eachGuidedConnectorHasOneFlowId() {
        #expect(app("discord", method: .botTokenStdio).setupGuideEntry?.setupFlowID == "discord")
        #expect(app("github", method: .apiKey).setupGuideEntry?.setupFlowID == "owner-setup-github")
        #expect(app("figma", method: .oauthClient, guide: false).oauthClientEntry?.setupFlowID == "owner-setup-figma")
        #expect(app("linear", method: .mcpOAuth, guide: false).setupGuideEntry == nil)
    }
}
