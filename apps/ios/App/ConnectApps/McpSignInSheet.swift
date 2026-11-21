import PalAuth
import PalConnect
import PalDesign
import SwiftUI

struct McpSignInSheet: View {
    let controller: McpSignInController
    let close: () -> Void

    @State private var address = ""
    @State private var clipboardMark: Int?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var phase: McpSignInPhase { controller.phase }

    private var showsProgress: Bool {
        switch phase {
        case .inBrowser, .pasteAddress: true
        default: false
        }
    }

    private var showsChecklist: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        SheetChrome(
            title: String(localized: "Connect \(controller.vendor)"),
            accessibilityIdentifier: "mcpSignIn",
            leadingAccessibilityIdentifier: "mcpSignInClose",
            onLeading: close,
            content: { flow }
        )
        .task { await controller.start() }
        .onChange(of: phase) { _, new in
            if new == .dismissed { close() }
        }
        .onDisappear {
            scrubClipboard()
            Task { await controller.cancel() }
        }
    }

    private var flow: some View {
        VStack(spacing: 0) {
            if showsProgress, !showsChecklist, let engine = controller.engine { StepFlowSegments(engine: engine) }
            HStack(spacing: 0) {
                if showsProgress, showsChecklist, let engine = controller.engine { StepFlowChecklist(engine: engine, savedNote: nil) }
                screen.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch phase {
        case .inBrowser:
            calm(.spinner, McpSignInSteps.waiting(vendor: controller.vendor))
        case .pasteAddress:
            pasteScreen
        case .waitingForAdmin:
            calm(.pending, McpSignInSteps.admin(vendor: controller.vendor))
        case .signedIn:
            calm(.success, McpSignInSteps.success(vendor: controller.vendor))
        case .failed(let status):
            StatusBlock(status: status, identifierPrefix: "mcpSignInStatus") { act(on: status) }
        case .dismissed:
            Color.clear
        }
    }

    private func calm(_ mark: StepFlowCalmCopy.Mark, _ copy: (title: String, body: String)) -> some View {
        StepFlowCalmView(copy: StepFlowCalmCopy(mark: mark, title: copy.title, body: copy.body))
    }

    private func act(on status: SetupStatus) {
        if status.kind == .forbidden { close() } else { Task { await controller.retry() } }
    }

    private var pasteScreen: some View {
        let shape = McpPasteShape.of(address)
        let problem = controller.pasteProblem
        return ScrollView {
            VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                Text("Paste the address")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("mcpSignInPasteTitle")
                Text("After you approve, the page will fail to load. Copy its address and paste it here.")
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mcpSignInPasteInstructions")
                if !controller.platform.returnsAutomatically {
                    Text("Automatic return isn't available on this device, so this one step is manual.")
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(PalTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mcpSignInPasteManualNote")
                }
                VStack(alignment: .leading, spacing: 5) {
                    SecretField(
                        String(localized: "Address"), prompt: String(localized: "Paste the address here"), text: $address,
                        identifier: "mcpSignInPasteField"
                    )
                    .textFieldStyle(.plain)
                    .disabled(controller.isSubmitting)
                    .onSubmit(submit)
                    .onChange(of: address) { old, new in
                        if old.isEmpty, new.count > 8 { clipboardMark = PasteboardScrub(SystemPasteboard()).mark() }
                    }
                    .padding(PalMetrics.screenMargin)
                    .background(PalTokens.control, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
                            .strokeBorder(border(shape: shape, problem: problem), lineWidth: 1.5)
                    }
                    if let message = problem ?? shape.message {
                        Text(message)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(problem == nil && shape == .valid ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("mcpSignInPasteStatus")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PalMetrics.screenMargin)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func border(shape: McpPasteShape, problem: String?) -> Color {
        if problem != nil { return Color.red }
        switch shape {
        case .empty: return Color.clear
        case .valid: return Color.green.opacity(0.5)
        case .notAnAddress, .missingCode: return Color.red
        }
    }

    @ViewBuilder
    private var footer: some View {
        if hasFooter {
            let phone = !showsChecklist
            let stack = phone ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            stack {
                if phone { primary }
                if !phone { Spacer(minLength: 0) }
                secondary
                quiet
                if !phone { primary }
            }
            .padding(.horizontal, PalMetrics.screenMargin)
            .padding(.vertical, PalMetrics.screenMargin)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { PalHairline() }
        }
    }

    private var hasFooter: Bool {
        switch phase {
        case .inBrowser, .pasteAddress, .signedIn: true
        case .waitingForAdmin, .failed, .dismissed: false
        }
    }

    @ViewBuilder
    private var primary: some View {
        let phone = !showsChecklist
        switch phase {
        case .pasteAddress:
            SetupButton(
                title: String(localized: "Finish sign-in"), kind: .primary, isBusy: controller.isSubmitting, fillsWidth: phone,
                identifier: "mcpSignInPrimary", action: submit
            )
            .disabled(McpPasteShape.of(address) != .valid)
            #if os(iOS)
            .controlSize(.large)
            #endif
        case .signedIn:
            SetupButton(title: String(localized: "Done"), kind: .primary, fillsWidth: phone, identifier: "mcpSignInPrimary", action: close)
            #if os(iOS)
                .controlSize(.large)
            #endif
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var secondary: some View {
        if phase == .pasteAddress {
            SetupButton(
                title: String(localized: "Open the sign-in page again"), fillsWidth: !showsChecklist, identifier: "mcpSignInReopen"
            ) { controller.reopen() }
            .disabled(controller.isSubmitting)
        }
    }

    @ViewBuilder
    private var quiet: some View {
        switch phase {
        case .inBrowser, .pasteAddress:
            SetupQuietButton(title: String(localized: "Cancel"), identifier: "mcpSignInCancel") {
                address = ""
                scrubClipboard()
                Task { await controller.cancel() }
            }
        default:
            EmptyView()
        }
    }

    private func submit() {
        let value = address
        guard McpPasteShape.of(value) == .valid else { return }
        address = ""
        scrubClipboard()
        Task { await controller.submit(value) }
    }

    private func scrubClipboard() {
        guard let mark = clipboardMark else { return }
        PasteboardScrub(SystemPasteboard()).clear(ifUnchangedSince: mark)
        clipboardMark = nil
    }
}
