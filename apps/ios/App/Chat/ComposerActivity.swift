import SwiftUI

final class ComposerActivity {
    var focused = false
    var draft = ""
}

extension EnvironmentValues {
    @Entry var composerActivity = ComposerActivity()
}

private struct ComposerActivityReporter: ViewModifier {
    let focused: Bool
    let draft: String
    @State private var activity = ComposerActivity()

    func body(content: Content) -> some View {
        content
            .environment(\.composerActivity, activity)
            .onChange(of: focused, initial: true) { _, now in activity.focused = now }
            .onChange(of: draft, initial: true) { _, now in activity.draft = now }
    }
}

extension View {
    func composerActivity(focused: Bool, draft: String) -> some View {
        modifier(ComposerActivityReporter(focused: focused, draft: draft))
    }
}
