import PalAuth
import PalConnect
import PalDesign
import SwiftUI

struct SetupGuideStepView: View {
    let model: SetupGuideModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        let step = model.step
        ScrollView {
            VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
                header(step)
                if step.kind == .publicURL { address }
                if !step.links.isEmpty { links(step.links) }
                if !step.copies.isEmpty { copies(step.copies) }
                if let fallback = step.fallback { SetupFallbackCard(fallback: fallback).id(step.id) }
                if step.kind == .serverPicker { SetupServerPicker(model: model) }
                if step.kind == .paste {
                    SetupPasteFields(model: model, step: step).id(step.id)
                } else if step.kind == .access {
                    SetupAccessChoice(model: model)
                } else {
                    PillButton(
                        model.isLastStep ? String(localized: "Done") : String(localized: "Next"), kind: .accent, size: .large,
                        accessibilityIdentifier: "setupGuideNext"
                    ) { Task { await model.advance() } }
                    .disabled(!model.canAdvance)
                    .padding(.horizontal, PalMetrics.screenMargin)
                }
                if model.showsBack {
                    PillButton(String(localized: "Back"), size: .large, accessibilityIdentifier: "setupGuideBack") { model.back() }
                        .padding(.horizontal, PalMetrics.screenMargin)
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setupGuideStep-\(step.id)")
    }

    private func header(_ step: SetupStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(
                String(localized: "Step \(model.index + 1) of \(model.stepCount)"), accessibilityIdentifier: "setupGuideProgress"
            )
            Text(step.title)
                .hermesText(.sheetTitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("setupGuideTitle")
            if !step.body.isEmpty {
                Text(step.body)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setupGuideBody")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PalMetrics.screenMargin)
    }

    @ViewBuilder
    private var address: some View {
        if let problem = model.step.problem {
            SetupAddressProblem(problem: problem, host: model.step.problemHost)
        } else if let address = model.publicAddress {
            SetupCopyCard(label: String(localized: "Web address"), value: address, identifier: "setupGuideAddress")
        }
        SetupAddressEditor(model: model)
    }

    private func copies(_ copies: [SetupCopy]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(copies.enumerated()), id: \.offset) { offset, copy in
                SetupCopyCard(label: copy.label, value: copy.value, identifier: "setupGuideCopy-\(offset)")
            }
        }
    }

    private func links(_ links: [SetupLink]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(links.enumerated()), id: \.offset) { offset, link in
                PillButton(link.label, size: .large, accessibilityIdentifier: "setupGuideLink-\(offset)") { ExternalLink.open(link.url) }
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}

private struct SetupAddressProblem: View {
    let problem: SetupProblem
    let host: String?

    var body: some View {
        ChatInstallStatus(
            copy: ChatStatusCopy(
                symbol: "exclamationmark.triangle", title: String(localized: "Google refuses this address"),
                reason: String(
                    localized: "Use your own domain for your Pal's address, or create a Desktop app client in Google Cloud, which needs no public address."
                ),
                code: problem.details(host: host)
            ),
            primaryTitle: nil, isBusy: false, perform: {}, identifierPrefix: "setupGuideAddressProblem",
            secondary: { EmptyView() }
        )
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}

private struct SetupFallbackCard: View {
    let fallback: SetupFallback

    @State private var revealed = false
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PillButton(fallback.label, size: .large, accessibilityIdentifier: "setupGuideFallback") { revealed.toggle() }
            if revealed {
                Text(fallback.body)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setupGuideFallbackBody")
                ForEach(Array(fallback.links.enumerated()), id: \.offset) { offset, link in
                    PillButton(link.label, size: .large, accessibilityIdentifier: "setupGuideFallbackLink-\(offset)") { ExternalLink.open(link.url) }
                }
            }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
    }
}

private struct SetupCopyCard: View {
    let label: String
    let value: String
    let identifier: String

    @State private var copied = false
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SectionCaption(label, accessibilityIdentifier: "\(identifier)Caption")
            GroupedCard(accessibilityIdentifier: "\(identifier)Card") {
                HStack(alignment: .top, spacing: 12) {
                    Text(value)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("\(identifier)Value")
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                        Pasteboard.string = value
                        copied = true
                    }
                    .buttonStyle(.pill())
                    .accessibilityIdentifier("\(identifier)Button")
                }
                .padding(.horizontal, PalMetrics.rowInset)
                .padding(.vertical, PalMetrics.rowVerticalPadding)
            }
        }
    }
}

private struct SetupPasteFields: View {
    let model: SetupGuideModel
    let step: SetupStep

    @State private var values: [String: String] = [:]
    @State private var clipboardMark: Int?
    @Environment(\.hermesTheme) private var theme

    private var ready: Bool { step.fields.allSatisfy { $0.shape(of: values[$0.id] ?? "").isValid } }

    var body: some View {
        VStack(alignment: .leading, spacing: PalMetrics.cardGap) {
            VStack(spacing: 10) {
                ForEach(step.fields) { field in entry(field) }
            }
            .padding(.horizontal, PalMetrics.screenMargin)
            PillButton(
                step.check == nil ? String(localized: "Save") : String(localized: "Check and save"), kind: .accent, size: .large,
                accessibilityIdentifier: "setupGuideSubmit", action: submit
            )
            .disabled(!ready)
            .padding(.horizontal, PalMetrics.screenMargin)
            CardFootnote(
                String(localized: "Saved on your Pal for every device. They can't be read back."), accessibilityIdentifier: "setupGuideFieldsNote"
            )
        }
    }

    private func binding(_ field: SetupField) -> Binding<String> {
        Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
    }

    private func entry(_ field: SetupField) -> some View {
        let shape = field.shape(of: values[field.id] ?? "")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                input(field)
                Button(String(localized: "Paste")) { paste(field) }
                    .buttonStyle(.pill())
                    .accessibilityIdentifier("setupGuidePaste-\(field.id)")
            }
            .padding(12)
            .background(PalTokens.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let hint = shape.hint {
                Text(hint)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("setupGuideHint-\(field.id)")
            } else if shape.isValid {
                Text("Looks right")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("setupGuideShapeOK-\(field.id)")
            }
        }
    }

    @ViewBuilder
    private func input(_ field: SetupField) -> some View {
        if field.secret {
            SecretField(field.label, text: binding(field), identifier: "setupGuideField-\(field.id)")
                .textFieldStyle(.plain)
                .onChange(of: values[field.id] ?? "") { old, new in
                    if old.isEmpty, new.count > 8 { clipboardMark = PasteboardScrub(SystemPasteboard()).mark() }
                }
        } else {
            TextField(field.label, text: binding(field))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("setupGuideField-\(field.id)")
        }
    }

    private func paste(_ field: SetupField) {
        guard let text = SecretEntryInput.trimmed(Pasteboard.string ?? "") else { return }
        values[field.id] = text
        if field.secret { clipboardMark = PasteboardScrub(SystemPasteboard()).mark() }
    }

    private func submit() {
        guard ready else { return }
        let sent = values.compactMapValues { SecretEntryInput.trimmed($0) }
        values = [:]
        if let mark = clipboardMark { PasteboardScrub(SystemPasteboard()).clear(ifUnchangedSince: mark) }
        clipboardMark = nil
        Task { await model.submit(sent) }
    }
}
