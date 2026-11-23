import PalBotProfile
import PalDesign
import SwiftUI

struct SlackLinkView: View {
    @State private var model: SlackModel
    let spec: BotAvatarSpec?
    let closeSheet: (() -> Void)?
    let close: () -> Void

    init(model: SlackModel, spec: BotAvatarSpec?, closeSheet: (() -> Void)?, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.spec = spec
        self.closeSheet = closeSheet
        self.close = close
    }

    var body: some View {
        content
            .task { await model.load() }
            .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let link = model.link, !model.isEnteringTokens {
            SlackLinkStatusView(model: model, link: link, spec: spec, close: close)
        } else if let closeSheet {
            SheetChrome(title: String(localized: "Slack"), accessibilityIdentifier: "slackScreenSheet", onLeading: closeSheet) {
                SlackTokensView(model: model)
            }
        } else {
            SlackTokensView(model: model)
        }
    }
}
