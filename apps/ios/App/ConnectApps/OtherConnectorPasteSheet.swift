import PalAuth
import PalConnect
import PalDesign
import SwiftUI

struct OtherConnectorPasteSheet: View {
    let model: ConnectAppsModel
    let app: ConnectApp

    var body: some View {
        SheetChrome(
            title: app.name,
            accessibilityIdentifier: "otherConnectorPaste",
            leadingAccessibilityIdentifier: "otherConnectorPasteCancel",
            onLeading: { Task { await model.cancelPaste() } },
            content: {
                ScrollView {
                    PasteAddressEntry(
                        state: model.pasteState,
                        identifiers: SecretEntryIdentifiers(
                            field: "other-paste-field", submit: "other-paste-submit", cancel: "other-paste-cancel", status: "other-paste-status"
                        ),
                        onSubmit: { value in Task { await model.submitPastedAddress(value) } },
                        onReopen: { model.reopenPasteSignIn() },
                        onCancel: { Task { await model.cancelPaste() } }
                    )
                    .padding(.horizontal, 4)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        )
    }
}
