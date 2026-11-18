import PalAuth
import PalConnect
import PalDesign
import SwiftUI

struct StepCopyCard: View {
    let label: String
    let value: String
    let identifier: String

    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textTertiary)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(PalTokens.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .accessibilityIdentifier("\(identifier)Value")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SetupButton(
                title: copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc",
                identifier: "\(identifier)Button"
            ) {
                Pasteboard.string = value
                copied = true
            }
        }
        .padding(PalMetrics.screenMargin)
        .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct StepPasteFields: View {
    let model: StepFlowModel
    let fields: [SetupField]

    @State private var clipboardMark: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
            ForEach(fields) { field in entry(field) }
            Text("Saved on your Pal for every device. They can't be read back.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textTertiary)
                .accessibilityIdentifier("stepFlowFieldsNote")
        }
        .onDisappear { scrubClipboard() }
    }

    private func binding(_ field: SetupField) -> Binding<String> {
        Binding(get: { model.engine.value(for: field.id) }, set: { model.setValue($0, for: field.id) })
    }

    private func entry(_ field: SetupField) -> some View {
        let shape = model.engine.shape(of: field.id)
        return VStack(alignment: .leading, spacing: 5) {
            Text(field.label)
                .hermesText(.rowSubtitle)
                .fontWeight(.semibold)
                .foregroundStyle(PalTokens.textSecondary)
            input(field)
                .padding(PalMetrics.screenMargin)
                .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                        .strokeBorder(border(shape), lineWidth: 1.5)
                }
            if let message = shape.message(label: field.label) {
                Text(message)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(shape.isValid ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stepFlowHint-\(field.id)")
            }
        }
    }

    private func border(_ shape: SetupFieldShape) -> Color {
        switch shape {
        case .empty: Color.clear
        case .valid: Color.green.opacity(0.5)
        default: Color.red
        }
    }

    @ViewBuilder
    private func input(_ field: SetupField) -> some View {
        if field.secret {
            SecretField(field.label, text: binding(field), identifier: "stepFlowField-\(field.id)")
                .textFieldStyle(.plain)
                .onChange(of: model.engine.value(for: field.id)) { old, new in
                    if old.isEmpty, new.count > 8 { clipboardMark = PasteboardScrub(SystemPasteboard()).mark() }
                }
        } else {
            TextField(field.label, text: binding(field))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("stepFlowField-\(field.id)")
        }
    }

    private func scrubClipboard() {
        guard let mark = clipboardMark else { return }
        PasteboardScrub(SystemPasteboard()).clear(ifUnchangedSince: mark)
        clipboardMark = nil
    }
}
