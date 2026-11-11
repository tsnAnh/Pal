import HermesConnect
import HermesDesign
import SwiftUI

struct CustomConnectorStyle {
    let primary: Color
    let secondary: Color
    let field: Color
    let divider: Color
    let fieldRadius: CGFloat
    let fieldHeight: CGFloat
    let margin: CGFloat
    let spacing: CGFloat
    let maxWidth: CGFloat
    let titleFont: Font
    let labelFont: Font
    let bodyFont: Font
    let captionFont: Font

    static func phone(_ theme: HermesTheme) -> CustomConnectorStyle {
        CustomConnectorStyle(
            primary: Color(theme.palette.textPrimary), secondary: Color(theme.palette.textSecondary),
            field: Color(theme.palette.groupedCard), divider: Color(theme.palette.tileStroke),
            fieldRadius: HermesMetrics.cardRadius, fieldHeight: 48, margin: HermesMetrics.screenMargin, spacing: 18,
            maxWidth: .infinity, titleFont: .title3.weight(.semibold), labelFont: .footnote.weight(.medium),
            bodyFont: .body, captionFont: .footnote
        )
    }

    #if os(macOS)
    static let mac = CustomConnectorStyle(
        primary: PalTokens.textPrimary, secondary: PalTokens.textSecondary, field: PalTokens.control, divider: PalTokens.divider,
        fieldRadius: 10, fieldHeight: 32, margin: 29, spacing: 16, maxWidth: 440,
        titleFont: .system(size: 15, weight: .medium), labelFont: .system(size: 11, weight: .medium),
        bodyFont: .system(size: 12), captionFont: .system(size: 11)
    )
    #endif
}

struct CustomConnectorForm: View {
    @Bindable var model: CustomConnectorModel
    let style: CustomConnectorStyle
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CustomConnectorBody(model: model, style: style)
            Rectangle().fill(style.divider).frame(height: 1)
            footer
                .padding(.horizontal, style.margin)
                .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("customConnector")
        .task { await model.begin() }
        .confirmationDialog(
            "Remove \(model.existing?.name ?? "this connector")?",
            isPresented: $model.confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await model.remove() } }
                .accessibilityIdentifier("customConnectorRemoveConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your bots lose access to this connector.")
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if model.screen == .form {
                footerButton("Cancel", kind: .neutral, identifier: "customConnectorCancelButton", action: onCancel)
                Spacer(minLength: 12)
                footerButton(
                    model.submitTitle, kind: model.canSubmit ? .accent : .dimmed, identifier: "customConnectorAddButton"
                ) { Task { await model.submit() } }
                .disabled(!model.canSubmit)
            } else {
                footerButton("Remove", kind: .neutral, identifier: "customConnectorRemoveButton") { model.confirmingRemove = true }
                    .disabled(model.isBusy)
                Spacer(minLength: 12)
                footerButton("Edit", kind: model.isBusy ? .dimmed : .accent, identifier: "customConnectorEditButton") { model.edit() }
                    .disabled(model.isBusy)
            }
        }
        .frame(maxWidth: style.maxWidth)
        .frame(maxWidth: .infinity)
    }

    private func footerButton(_ title: String, kind: PillKind, identifier: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            #if os(macOS)
            .buttonStyle(.palPill(height: 28, fontSize: 12, fill: kind == .accent ? PalTokens.toggleOn.opacity(0.7) : nil))
            #else
            .buttonStyle(.pill(kind, size: .regular))
            #endif
            .accessibilityIdentifier(identifier)
    }
}

struct CustomConnectorBody: View {
    @Bindable var model: CustomConnectorModel
    let style: CustomConnectorStyle

    var body: some View {
        ScrollView {
            VStack(spacing: style.spacing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(RGB(hexString: BotLookCatalog.tealHex) ?? RGB(hex: 0x0ec79b)))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "powerplug.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white))
                    .accessibilityHidden(true)
                Text(model.heading)
                    .font(style.titleFont)
                    .foregroundStyle(style.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("customConnectorTitle")
                if model.screen == .form { formContent } else { resultContent }
            }
            .frame(maxWidth: style.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, style.margin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var formContent: some View {
        labeled("Name") {
            TextField("Add a name", text: $model.name)
                .modifier(FieldStyle(style: style))
                .disabled(model.isEditing || model.isBusy)
                .accessibilityIdentifier("customConnectorNameField")
        }
        labeled("Type") {
            Picker("Type", selection: $model.type) {
                ForEach(CustomConnectorType.options, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(style.bodyFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: style.fieldHeight)
            .background(style.field, in: RoundedRectangle(cornerRadius: style.fieldRadius, style: .continuous))
            .disabled(model.isBusy)
            .accessibilityIdentifier("customConnectorTypePicker")
        }
        labeled("Server URL") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("example.com/mcp", text: $model.url)
                    .modifier(FieldStyle(style: style))
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("customConnectorURLField")
                if let preview = model.addressPreview {
                    Text(preview)
                        .font(style.captionFont)
                        .foregroundStyle(style.secondary)
                        .accessibilityIdentifier("customConnectorURLPreview")
                }
            }
        }
        labeled("HTTP headers") { headerRows }
        labeled("Client ID") {
            TextField("Client ID", text: $model.clientID, prompt: Text(verbatim: ""))
                .modifier(FieldStyle(style: style))
                .disabled(model.isBusy)
                .accessibilityIdentifier("customConnectorClientIDField")
        }
        status
    }

    private var headerRows: some View {
        VStack(spacing: 8) {
            ForEach($model.headers) { $row in
                let index = model.index(ofHeader: row.id)
                HStack(spacing: 8) {
                    TextField("Key", text: $row.key)
                        .modifier(FieldStyle(style: style))
                        .disabled(row.isStored || model.isBusy)
                        .accessibilityIdentifier("customConnectorHeaderKey-\(index)")
                    SecureField("Value", text: $row.value, prompt: Text(verbatim: row.isStored ? "••••••••" : "Value"))
                        .modifier(FieldStyle(style: style))
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("customConnectorHeaderValue-\(index)")
                    if !row.isBlank {
                        Button { model.removeHeader(row.id) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(style.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .accessibilityLabel(Text("Remove header"))
                        .accessibilityIdentifier("customConnectorHeaderRemove-\(index)")
                    }
                }
            }
        }
        .onChange(of: model.headers) { _, _ in model.ensureTrailingHeaderRow() }
    }

    @ViewBuilder
    private var status: some View {
        if let progress = model.progressText {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(style.bodyFont).foregroundStyle(style.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("customConnectorProgress")
        }
        if let failure = model.failure {
            Text(failure.message)
                .font(style.captionFont)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("customConnectorError")
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        status
        if case .connected(let tools) = model.phase {
            sectionTitle(tools.count == 1 ? "1 tool" : "\(tools.count) tools")
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name).font(style.bodyFont).foregroundStyle(style.primary)
                    if !tool.description.isEmpty {
                        Text(tool.description).font(style.captionFont).foregroundStyle(style.secondary).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("customConnectorTool-\(tool.name)")
            }
        }
        if !model.switches.isEmpty {
            sectionTitle("Use with")
            ForEach(model.switches) { bot in
                Toggle(
                    bot.displayName,
                    isOn: Binding(get: { bot.isOn }, set: { on in Task { await model.setBot(bot.id, on: on) } })
                )
                .font(style.bodyFont)
                .disabled(bot.isBusy || model.isBusy)
                .accessibilityIdentifier("customConnectorBot-\(bot.id)")
            }
        }
        if let notice = model.switchNotice {
            Text(notice).font(style.captionFont).foregroundStyle(style.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("customConnectorNotice")
        }
        if let failure = model.removeFailure {
            Text(failure.message).font(style.captionFont).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("customConnectorRemoveError")
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(style.labelFont).foregroundStyle(style.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(style.labelFont)
            .foregroundStyle(style.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct FieldStyle: ViewModifier {
    let style: CustomConnectorStyle

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(style.bodyFont)
            .neverAutocapitalized()
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .frame(height: style.fieldHeight)
            .background(style.field, in: RoundedRectangle(cornerRadius: style.fieldRadius, style: .continuous))
    }
}
