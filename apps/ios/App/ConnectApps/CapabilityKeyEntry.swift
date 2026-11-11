import HermesBotProfile
import HermesDesign
import SwiftUI

struct CapabilityKeyEntrySheet: View {
    let model: ConnectAppsModel
    let request: CapabilityKeyRequest

    var body: some View {
        SecretEntryView(
            connectorName: request.capability,
            accountLabel: model.botName,
            purpose: String(localized: "Paste the key for \(request.keyName). It is saved for \(model.botName) only and can't be read back."),
            fieldLabel: request.keyName,
            state: model.keyState,
            identifiers: SecretEntryIdentifiers(
                field: "capability-key-field", submit: "capability-key-save-button",
                cancel: "capability-key-cancel-button", status: "capability-key-status"
            ),
            onSubmit: { value in Task { await model.submitKey(value) } },
            onCancel: { model.cancelKeyEntry() }
        )
        .padding(24)
    }
}

struct CapabilitySetKeyButton: View {
    let row: CapabilityRow
    let onSelect: (String) -> Void

    var body: some View {
        let keys = row.settableKeys
        if keys.count == 1, let key = keys.first {
            Button(String(localized: "Set key")) { onSelect(key) }
                .accessibilityIdentifier("capabilitySetKey-\(row.id)")
        } else if keys.count > 1 {
            Menu(String(localized: "Set key")) {
                ForEach(keys, id: \.self) { key in Button(key) { onSelect(key) } }
            }
            .accessibilityIdentifier("capabilitySetKey-\(row.id)")
        }
    }
}
