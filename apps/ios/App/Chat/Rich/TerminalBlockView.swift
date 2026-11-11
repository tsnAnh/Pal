import PalDesign
import SwiftUI

struct TerminalBlockView: View {
    let source: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let plain = RichRendering.plainTerminal(source)
        RichCardFrame(title: String(localized: "Terminal"), copyText: plain, identifier: "terminalBlock") {
            ExpandableBlock(lineCount: RichCode.lineCount(plain)) {
                Text(RichRendering.terminal(source, scheme: colorScheme))
                    .hermesText(.chatCode)
                    .font(RichCode.font)
                    .foregroundStyle(PalTokens.textPrimary)
                    .textSelection(.enabled)
            }
        }
    }
}
