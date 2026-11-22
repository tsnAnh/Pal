import SwiftUI

final class ComposerActivity {
    var focused = false
    var draft = ""
}

extension EnvironmentValues {
    @Entry var composerActivity = ComposerActivity()
}

private struct ComposerActivityProvider: ViewModifier {
    let focused: Bool
    @State private var activity = ComposerActivity()

    func body(content: Content) -> some View {
        content
            .environment(\.composerActivity, activity)
            .onChange(of: focused, initial: true) { _, now in activity.focused = now }
    }
}

private struct ComposerDraftReporter: ViewModifier {
    let draft: String
    @Environment(\.composerActivity) private var activity

    func body(content: Content) -> some View {
        content.onChange(of: draft, initial: true) { _, now in activity.draft = now }
    }
}

extension View {
    func composerActivity(focused: Bool) -> some View {
        modifier(ComposerActivityProvider(focused: focused))
    }

    func reportsComposerDraft(_ draft: String) -> some View {
        modifier(ComposerDraftReporter(draft: draft))
    }
}
