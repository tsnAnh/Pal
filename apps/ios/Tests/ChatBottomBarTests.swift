#if os(macOS)
import AppKit
import PalChat
import PalDesign
import PalProtocol
import SwiftUI
import Testing

@testable import Pal

private struct BottomBarHost: View {
    let environment: MacChatBenchEnvironment

    @State private var dictation = DictationController()
    @State private var isVoiceModePresented = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ChatBottomBar(
            model: environment.model,
            router: environment.router,
            scroll: ChatScrollController(),
            dictation: dictation,
            draft: .constant(""),
            focused: $composerFocused,
            isVoiceModePresented: $isVoiceModePresented
        )
    }
}

@MainActor
@Suite("Chat bottom bar", .serialized)
struct ChatBottomBarTests {
    private func height(_ environment: MacChatBenchEnvironment) -> CGFloat {
        let bar = BottomBarHost(environment: environment)
            .environment(environment.hub)
            .environment(environment.shell)
            .environment(environment.autoApprove)
            .environment(environment.appearance)
            .hermesTheme(mode: environment.appearance.mode)
            .frame(width: 600)
        return NSHostingView(rootView: bar).fittingSize.height
    }

    private func draftApproval(_ index: Int) throws -> PendingPrompt {
        let wire: JSONValue = [
            "kind": "approval", "prompt_id": .string("d\(index)"), "execution_generation": 1, "question": "Send this message to Sam?",
            "command": "Running late.", "choices": ["once", "deny"], "draft": ["channel": "telegram", "held": false],
        ]
        return try wire.decoded(as: PendingPrompt.self)
    }

    @Test("no bar sits above the composer while the gateway has draft approvals open", arguments: [1, 6])
    func noBarAboveTheComposer(open: Int) throws {
        let environment = try MacChatBenchSession.environment()
        var snapshot = RebuildWorld().snapshot(version: 1)
        environment.model.apply(snapshot)
        let composerAlone = height(environment)
        snapshot.version = 2
        snapshot.pendingPrompts = try (1...open).map(draftApproval)
        environment.model.apply(snapshot)
        #expect(environment.model.isAskingClarify)
        #expect(composerAlone > 0)
        #expect(height(environment) == composerAlone)
    }
}
#endif
