#if os(macOS)
import AppKit
import PalChat
import PalClient
import PalConnect
import PalDesign
import SwiftUI

@testable import Pal

@MainActor
@Observable
final class MacChatBenchDraft {
    var text = ""
}

struct MacChatBenchSurface: View {
    let model: ChatModel
    let draft: MacChatBenchDraft
    let teach: TeachModel
    let router: AppRouter
    let scroll: ChatScrollController

    @State private var dictation = DictationController()
    @State private var isVoiceModePresented = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        ChatTranscriptList(model: model, scroll: scroll, teach: teach, router: router)
            .palSafeAreaBar(edge: .bottom) {
                ChatBottomBar(
                    model: model,
                    router: router,
                    scroll: scroll,
                    dictation: dictation,
                    draft: Binding(get: { draft.text }, set: { draft.text = $0 }),
                    focused: $composerFocused,
                    isVoiceModePresented: $isVoiceModePresented
                )
                .chatColumn()
                .paneOverflowProbe("chat.composer")
            }
            .macChatChrome(model: model, router: router, find: {}, focusComposer: {})
            .background(PalTokens.content)
            .messageMenuPresenter().composerActivity(focused: composerFocused)
            .onAppear { scroll.setVisible(true, rowIDs: model.rowIDs) }
    }
}

@MainActor
struct MacChatBenchEnvironment {
    let hub: SettingsHub
    let shell: MacShell
    let autoApprove: ActionAutoApprove
    let appearance: AppearanceStore
    let router: AppRouter
    let teach: TeachModel
    let model: ChatModel

    init(model: ChatModel) {
        let roster = model.roster
        let connection = roster.connection
        hub = SettingsHub(connection: connection, roster: roster)
        shell = MacShell(defaults: UserDefaults(suiteName: "mac-chat-bench-\(UUID().uuidString)") ?? .standard)
        autoApprove = ActionAutoApprove { method, params in try await connection.rpc(method, params) }
        appearance = AppearanceStore()
        router = AppRouter(capabilities: [.botProfile, .connectApps, .kanban])
        teach = BotsKit(connection: connection).teach(for: model.bot.name, displayName: model.bot.displayName)
        self.model = model
    }

    func surface(draft: MacChatBenchDraft, scroll: ChatScrollController) -> some View {
        MacChatBenchSurface(model: model, draft: draft, teach: teach, router: router, scroll: scroll)
            .environment(hub)
            .environment(shell)
            .environment(autoApprove)
            .environment(appearance)
            .hermesTheme(mode: appearance.mode)
            .macModalEnvironment()
    }
}

final class MacChatBenchWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class MacChatBenchHost {
    let window: MacChatBenchWindow
    let view: NSHostingView<AnyView>

    init(root: some View, size: CGSize) {
        view = NSHostingView(rootView: AnyView(root))
        window = MacChatBenchWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.sharingType = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
        window.contentView = view
        window.setFrameOrigin(NSScreen.screens.first?.frame.origin ?? .zero)
        window.orderFrontRegardless()
    }

    var isAtNewest: Bool {
        guard let scrollView = transcriptScrollView, let document = scrollView.documentView else { return false }
        return document.frame.height > scrollView.contentView.bounds.height
            && scrollView.contentView.bounds.origin.y <= -scrollView.contentInsets.top + 0.5
    }

    private var scrollSignature: [CGFloat] {
        guard let scrollView = transcriptScrollView else { return [] }
        return [scrollView.contentView.bounds.origin.y, scrollView.documentView?.frame.height ?? 0]
    }

    @discardableResult
    func settleAtNewest(stableFrames: Int = 10, maxFrames: Int) -> Int {
        var stable = 0
        var previous: [CGFloat] = []
        for frame in 1...maxFrames {
            settle()
            let current = scrollSignature
            stable = isAtNewest && current == previous ? stable + 1 : 0
            previous = current
            if stable >= stableFrames { return frame }
        }
        return maxFrames
    }

    func liveScroll(_ name: Notification.Name) {
        guard let scrollView = transcriptScrollView else { return }
        NotificationCenter.default.post(name: name, object: scrollView)
    }

    func scroll(by points: Double) {
        guard let scrollView = transcriptScrollView else { return }
        let clip = scrollView.contentView
        let newest = -scrollView.contentInsets.top
        let oldest = (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height + scrollView.contentInsets.bottom
        let next = min(max(newest, clip.bounds.origin.y + points), oldest)
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: next))
        scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    func resize(to size: CGSize) {
        window.setContentSize(size)
    }

    func settle() {
        let end = Date(timeIntervalSinceNow: MacChatBench.framePeriod)
        while Date() < end { RunLoop.main.run(mode: .default, before: end) }
    }

    func close() {
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    var occlusion: String { "visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) screen=\(window.screen != nil)" }

    var transcriptScrollView: NSScrollView? {
        Self.scrollViews(in: view).max { $0.bounds.height * $0.bounds.width < $1.bounds.height * $1.bounds.width }
    }

    func descendantCount() -> Int {
        Self.descendants(of: view).count
    }

    func snapshot(to url: URL) throws {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw MacChatBenchError.snapshotUnavailable }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw MacChatBenchError.snapshotUnavailable }
        try data.write(to: url)
    }

    private static func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func scrollViews(in root: NSView) -> [NSScrollView] {
        descendants(of: root).compactMap { $0 as? NSScrollView }
    }
}

enum MacChatBenchError: Error {
    case snapshotUnavailable
    case openNeverSettled
    case noTranscriptScrollView
}
#endif
