import PalConnect
import PalDesign
import SwiftUI

struct StepFlowView<Accessory: View>: View {
    let model: StepFlowModel
    let title: String
    let app: ConnectApp?
    let savedNote: String?
    let close: () -> Void
    let accessory: (FlowStep) -> Accessory
    private(set) var headerContent: AnyView?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    init(
        model: StepFlowModel, title: String, app: ConnectApp? = nil, savedNote: String? = nil, close: @escaping () -> Void,
        @ViewBuilder accessory: @escaping (FlowStep) -> Accessory
    ) {
        self.model = model
        self.title = title
        self.app = app
        self.savedNote = savedNote
        self.close = close
        self.accessory = accessory
    }

    private var engine: StepFlowEngine { model.engine }

    func header(_ content: some View) -> Self {
        var copy = self
        copy.headerContent = AnyView(content)
        return copy
    }

    private var inlineRefusal: SetupStatus? {
        guard let failure = engine.failure, failure.kind == .vendorRefusedValue, engine.current.inlineRefusal,
              case .paste = engine.current.kind
        else { return nil }
        return failure
    }

    private var layout: StepFlowLayout {
        #if os(macOS)
        .stepper
        #else
        StepFlowLayout(sizeClass: sizeClass)
        #endif
    }

    var body: some View {
        SetupChrome(title: title, app: app, progress: engine, accessibilityIdentifier: "stepFlow", close: close) {
            VStack(spacing: 0) {
                if layout.showsSegments { StepFlowSegments(engine: engine, layout: layout) }
                if let headerContent { headerContent }
                HStack(spacing: 0) {
                    if layout.showsChecklist { StepFlowChecklist(engine: engine, savedNote: savedNote) }
                    screen.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer
            }
        }
        .task(id: ObjectIdentifier(model)) {
            model.openPage = { _ = ExternalLink.open($0) }
            await model.start()
        }
        .onDisappear { model.cancelWork() }
    }

    @ViewBuilder
    private var screen: some View {
        if let failure = engine.failure, inlineRefusal == nil {
            StatusBlock(status: failure, identifierPrefix: "stepFlowStatus") { perform(after: failure) }
        } else if let calm = calmCopy {
            StepFlowCalmScreen(copy: calm) { accessory(engine.current) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                    Text(engine.current.screenTitle)
                        .stepTitleStyle(layout)
                        .foregroundStyle(PalTokens.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("stepFlowStepTitle")
                    if !engine.current.body.isEmpty {
                        Text(Self.inlineMarkdown(engine.current.body))
                            .hermesText(.rowTitle)
                            .foregroundStyle(PalTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stepFlowStepBody")
                    }
                    if layout.keepsLinksInContent { pageLink }
                    if let continuation = model.continuation, continuation.stepID == engine.current.id {
                        SetupBanner(title: continuation.title, detail: continuation.detail, identifier: "stepFlowContinued")
                    }
                    if let note = engine.current.note {
                        Text(note)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(PalTokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stepFlowNote")
                    }
                    stepContent
                    if !engine.current.links.isEmpty { StepFlowLinks(links: engine.current.links) }
                    accessory(engine.current)
                    if layout.keepsLinksInContent, let savedNote {
                        Text(savedNote)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(PalTokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("stepFlowSavedNote")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(layout.contentInsets)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .id(engine.current.id)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch engine.current.kind {
        case .intro(let youDo, let palDoes):
            StepIntroCard(youDo: youDo, palDoes: palDoes)
        case .copyCard(let copies):
            ForEach(Array(copies.enumerated()), id: \.offset) { offset, copy in
                StepCopyCard(label: copy.label, value: copy.value, identifier: "stepFlowCopy-\(offset)")
            }
        case .paste(let fields) where !fields.isEmpty:
            StepPasteFields(model: model, fields: fields, refusal: inlineRefusal)
        case .confirm(let items):
            StepConfirmList(model: model, items: items)
        case .openAndCheck(let open):
            ForEach(Array(open.copies.enumerated()), id: \.offset) { offset, copy in
                StepCopyCard(label: copy.label, value: copy.value, identifier: "stepFlowCopy-\(offset)")
            }
        case .switches(let groups):
            StepSwitchGroups(model: model, groups: groups)
        default:
            EmptyView()
        }
    }

    private var calmCopy: StepFlowCalmCopy? {
        if engine.phase == .preparing { return StepFlowCalmCopy(mark: .spinner, title: engine.current.screenTitle, body: "") }
        if engine.phase == .working, let title = engine.current.workingTitle {
            return StepFlowCalmCopy(mark: .spinner, title: title, body: engine.current.workingBody)
        }
        return switch engine.current.kind {
        case .waiting(let title, let body): StepFlowCalmCopy(mark: .spinner, title: title, body: body)
        case .success(let title, let body): StepFlowCalmCopy(mark: .success, title: title, body: body)
        case .browserRoundTrip(let title, let body) where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: title, body: body)
        case .action(let title, let body) where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: title, body: body)
        case .openAndCheck(let open) where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: open.waitingTitle, body: open.waitingBody)
        case .automatic where engine.phase == .working:
            StepFlowCalmCopy(mark: .spinner, title: engine.current.screenTitle, body: engine.current.body)
        default: nil
        }
    }

    private var footerLayout: StepFlowLayout { layout.footerLayout(at: dynamicTypeSize) }

    private var footer: some View {
        Group {
            switch footerLayout {
            case .stacked:
                VStack(spacing: SetupFooterMetrics.buttons(fillsWidth: true).buttonSpacing) {
                    primary
                    back
                    quiet
                    pageLink
                }
            case .rail:
                HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
                    Spacer(minLength: 0)
                    back
                    quiet
                    pageLink
                    primary
                }
            case .stepper:
                HStack(spacing: SetupFooterMetrics.mac.buttonSpacing) {
                    back
                    Spacer(minLength: 0)
                    quiet
                    primary
                }
            }
        }
        .setupFooter(fillsWidth: footerLayout.fillsWidth)
    }

    @ViewBuilder
    private var back: some View {
        if engine.canGoBack, engine.phase != .working {
            SetupButton(title: String(localized: "Back"), fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowBack") {
                Task { await model.back() }
            }
        }
    }

    @ViewBuilder
    private var quiet: some View {
        if engine.phase == .working {
            SetupQuietButton(title: String(localized: "Cancel"), fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowCancel") {
                model.cancelWork()
            }
        } else if case .waiting = engine.current.kind {
            SetupQuietButton(title: String(localized: "Cancel"), fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowCancel") {
                Task { await model.back() }
            }
        } else if engine.canSkip, let title = engine.current.skipTitle {
            SetupQuietButton(title: title, fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowSkip") { Task { await model.skip() } }
        } else if case .openAndCheck(let open) = engine.current.kind, engine.phase == .ready {
            SetupQuietButton(title: open.recheckTitle, fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowRecheck") {
                Task { await model.recheck() }
            }
        }
    }

    @ViewBuilder
    private var pageLink: some View {
        if let link = engine.current.pageLink, engine.failure == nil, engine.phase != .working {
            SetupButton(title: link.label, fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowPage") { model.openPage(link.url) }
        }
    }

    @ViewBuilder
    private var primary: some View {
        if engine.failure == nil || inlineRefusal != nil, engine.phase != .working, engine.phase != .preparing, engine.primaryAction != .none {
            SetupButton(title: primaryTitle, kind: .primary, fillsWidth: footerLayout.fillsWidth, identifier: "stepFlowPrimary") {
                if engine.primaryAction == .finish { close() } else { Task { await model.performPrimary() } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!engine.isPrimaryEnabled || inlineRefusal != nil)
        }
    }

    private var primaryTitle: String {
        let step = engine.current
        if let title = step.primaryTitle { return title }
        switch step.kind {
        case .intro: return String(localized: "Start")
        case .instruction(let link?): return link.label
        case .openAndCheck(let open): return open.link.label
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

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

extension StepFlowView where Accessory == EmptyView {
    init(model: StepFlowModel, title: String, app: ConnectApp? = nil, savedNote: String? = nil, close: @escaping () -> Void) {
        self.init(model: model, title: title, app: app, savedNote: savedNote, close: close) { _ in EmptyView() }
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
