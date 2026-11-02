import Foundation
import HermesRoster
import Testing

@Suite("Bot activity derivation")
struct BotActivityTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var link: GatewayLink = .connected
        var live: BotLiveState?
        var localPrompt = false
        var expected: BotActivity

        var testDescription: String { name }
    }

    private static func live(
        _ statuses: [LiveSessionStatus] = [],
        worker: TimeInterval? = nil,
        onboarding: Bool = false
    ) -> BotLiveState {
        BotLiveState(
            sessions: statuses,
            workerLastActive: worker.map { now.timeIntervalSince1970 - $0 },
            onboardingPending: onboarding
        )
    }

    private static let cases: [Case] = [
        Case(name: "no snapshot yet reads idle", live: nil, expected: .idle),
        Case(name: "empty live state reads idle", live: live(), expected: .idle),
        Case(name: "idle session reads idle", live: live([.idle]), expected: .idle),
        Case(name: "working session", live: live([.working]), expected: .working),
        Case(name: "admitted but unclaimed turn counts as working", live: live([.starting]), expected: .working),
        Case(name: "waiting on a prompt needs input", live: live([.waiting]), expected: .needsInput),
        Case(name: "needs input beats working in another session", live: live([.working, .waiting]), expected: .needsInput),
        Case(name: "one busy session among idle ones", live: live([.idle, .working, .idle]), expected: .working),
        Case(name: "unknown status is ignored", live: live([.unknown]), expected: .idle),
        Case(name: "local pending prompt needs input", live: live(), localPrompt: true, expected: .needsInput),
        Case(name: "local pending prompt without a snapshot", live: nil, localPrompt: true, expected: .needsInput),
        Case(name: "fresh worker heartbeat is working", live: live(worker: 30), expected: .working),
        Case(name: "worker just inside the window is working", live: live(worker: 149), expected: .working),
        Case(name: "worker at the window edge is idle", live: live(worker: 150), expected: .idle),
        Case(name: "stale worker is idle", live: live(worker: 3_600), expected: .idle),
        Case(name: "worker stamp from the future counts as fresh", live: live(worker: -5), expected: .working),
        Case(name: "onboarding pending needs attention", live: live(onboarding: true), expected: .attention(.setupIncomplete)),
        Case(name: "working beats attention", live: live([.working], onboarding: true), expected: .working),
        Case(name: "needs input beats attention", live: live([.waiting], onboarding: true), expected: .needsInput),
        Case(name: "reconnecting hides working", link: .reconnecting, live: live([.working]), expected: .offline),
        Case(name: "offline hides needs input", link: .offline, live: live([.waiting]), localPrompt: true, expected: .offline),
        Case(name: "offline hides attention", link: .offline, live: live(onboarding: true), expected: .offline),
        Case(name: "offline without a snapshot", link: .offline, live: nil, expected: .offline),
    ]

    @Test(arguments: cases)
    private func derives(_ scenario: Case) {
        let activity = BotActivity.derive(
            link: scenario.link,
            live: scenario.live,
            hasLocalPrompt: scenario.localPrompt,
            now: Self.now
        )
        #expect(activity == scenario.expected)
    }

    @Test func accessibilityLabelsAreStable() {
        #expect(BotActivity.offline.accessibilityValue == "offline")
        #expect(BotActivity.idle.accessibilityValue == "idle")
        #expect(BotActivity.working.accessibilityValue == "working")
        #expect(BotActivity.needsInput.accessibilityValue == "needs-input")
        #expect(BotActivity.attention(.setupIncomplete).accessibilityValue == "attention")
    }

    @Test func sessionStatusDecodesUnknownValuesTolerantly() throws {
        let decoded = try JSONDecoder().decode([LiveSessionStatus].self, from: Data(#"["working","waiting","starting","idle","exploding"]"#.utf8))
        #expect(decoded == [.working, .waiting, .starting, .idle, .unknown])
    }
}
