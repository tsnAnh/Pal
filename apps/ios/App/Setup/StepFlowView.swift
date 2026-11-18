import PalConnect
import PalDesign
import SwiftUI

struct StepFlowView<Accessory: View>: View {
    let model: StepFlowModel
    let title: String
    var savedNote: String?
    let close: () -> Void
    @ViewBuilder let accessory: (FlowStep) -> Accessory

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var engine: StepFlowEngine { model.engine }

    private var showsChecklist: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupHeader(title: title, close: close)
            if !showsChecklist { StepFlowSegments(engine: engine) }
            HStack(spacing: 0) {
                if showsChecklist { StepFlowChecklist(engine: engine, savedNote: savedNote) }
                screen.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .background(PalTokens.content)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stepFlow")
        .task {
            model.openPage = { _ = ExternalLink.open($0) }
            await model.start()
        }
        .onDisappear { model.cancelWork() }
    }

    @ViewBuilder
    private var screen: some View {
        if let failure = engine.failure {
            StatusBlock(status: failure, identifierPrefix: "stepFlowStatus") { perform(after: failure) }
        } else if let calm = calmCopy {
            StepFlowCalmView(copy: calm)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                    Text(engine.current.screenTitle)
                        .hermesText(.sheetTitle)
                        .foregroundStyle(PalTokens.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("stepFlowStepTitle")
                    if !engine.current.body.isEmpty {
                        Text(engine.current.body)
                            .hermesText(.rowTitle)
                            .foregroundStyle(PalTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stepFlowStepBody")
                    }
                    stepContent
                    accessory(engine.current)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PalMetrics.screenMargin)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .id(engine.current.id)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch engine.current.kind {
        case .copyCard(let copies):
            ForEach(Array(copies.enumerated()), id: \.offset) { offset, copy in
                StepCopyCard(label: copy.label, value: copy.value, identifier: "stepFlowCopy-\(offset)")
            }
        case .paste(let fields) where !fields.isEmpty:
            StepPasteFields(model: model, fields: fields)
        default:
            EmptyView()
        }
    }

    private var calmCopy: StepFlowCalmCopy? {
        switch engine.current.kind {
        case .waiting(let title, let body): StepFlowCalmCopy(mark: .spinner, title: title, body: body)
        case .success(let title, let body): StepFlowCalmCopy(mark: .success, title: title, body: body)
        case .browserRoundTrip(let title, let body) where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: title, body: body)
        case .action(let title, let body) where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: title, body: body)
        case .automatic where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: engine.current.screenTitle, body: engine.current.body)
        default: nil
        }
    }

    @ViewBuilder
    private var footer: some View {
        let phone = !showsChecklist
        let stack = phone ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        stack {
            if phone { primary }
            if !phone { Spacer(minLength: 0) }
            if engine.canGoBack, engine.phase != .working {
                SetupButton(title: String(localized: "Back"), fillsWidth: phone, identifier: "stepFlowBack") {
                    Task { await model.back() }
                }
            }
            quiet
            pageLink
            if !phone { primary }
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, PalMetrics.screenMargin)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { PalHairline() }
    }

    @ViewBuilder
    private var quiet: some View {
        if engine.phase == .working {
            SetupQuietButton(title: String(localized: "Cancel"), identifier: "stepFlowCancel") { model.cancelWork() }
        } else if case .waiting = engine.current.kind {
            SetupQuietButton(title: String(localized: "Cancel"), identifier: "stepFlowCancel") { Task { await model.back() } }
        } else if engine.canSkip, let title = engine.current.skipTitle {
            SetupQuietButton(title: title, identifier: "stepFlowSkip") { Task { await model.skip() } }
        }
    }

    @ViewBuilder
    private var pageLink: some View {
        if let link = engine.current.pageLink, engine.failure == nil, engine.phase != .working {
            SetupButton(title: link.label, fillsWidth: !showsChecklist, identifier: "stepFlowPage") { model.openPage(link.url) }
        }
    }

    @ViewBuilder
    private var primary: some View {
        if engine.failure == nil, engine.phase != .working, engine.primaryAction != .none {
            SetupButton(title: primaryTitle, kind: .primary, fillsWidth: !showsChecklist, identifier: "stepFlowPrimary") {
                if engine.primaryAction == .finish { close() } else { Task { await model.performPrimary() } }
            }
            .disabled(!engine.isPrimaryEnabled)
            #if os(iOS)
            .controlSize(.large)
            #endif
        }
    }

    private var primaryTitle: String {
        let step = engine.current
        if let title = step.primaryTitle { return title }
        switch step.kind {
        case .instruction(let link?): return link.label
        case .paste: return String(localized: "Check and save")
        case .browserRoundTrip: return String(localized: "Continue")
        case .success: return String(localized: "Done")
        default: return String(localized: "Next")
        }
    }

    private func perform(after failure: SetupStatus) {
        if failure.kind == .forbidden {
            close()
        } else {
            Task { await model.recover(from: failure) }
        }
    }
}

#Preview("Step flow") {
    let steps = [
        FlowStep(
            id: "open", title: "Open the console", body: "Create an OAuth client of type Web application.",
            kind: .instruction(openPage: nil), primaryTitle: "Open the console"
        ),
        FlowStep(
            id: "paste", title: "Paste the two values", kind: .paste(fields: [
                SetupField(id: "client_id", label: "Client ID"), SetupField(id: "client_secret", label: "Client secret", secret: true),
            ])
        ),
        FlowStep(id: "done", title: "Connected", kind: .success(title: "Connected", body: "You will not be asked again.")),
    ]
    if let engine = StepFlowEngine(flowID: "preview", steps: steps) {
        StepFlowView(model: StepFlowModel(engine: engine), title: "Example", close: {}, accessory: { _ in EmptyView() })
    }
}
