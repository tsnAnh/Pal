import PalBotProfile
import PalDesign
import SwiftUI
import UniformTypeIdentifiers

enum TemplateFileReader {
    static let fileExtension = "hermesbot"

    static func read(_ url: URL) async -> Result<Data, TemplateImportError> {
        guard url.pathExtension.lowercased() == fileExtension else { return .failure(.invalidFile) }
        return await Task.detached(priority: .userInitiated) { () -> Result<Data, TemplateImportError> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > TemplateImportClient.maximumBytes { return .failure(.tooLarge) }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty // perf-lint: ok inside Task.detached
            else { return .failure(.unreadable) }
            return .success(data)
        }.value
    }
}

struct CreateBotImportRow: View {
    @Bindable var importer: TemplateImportModel
    let roster: RosterModel
    let router: AppRouter

    @State private var choosing = false
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Button { choosing = true } label: {
                HStack(spacing: 6) {
                    if importer.phase == .reading { ProgressView().controlSize(.small) }
                    Text("Import a template")
                }
            }
            .buttonStyle(.pill())
            .disabled(importer.isBusy)
            .accessibilityIdentifier("createBotImport")
            if importer.phase == .idle, let failure = importer.failure {
                Text(failure.message)
                    .hermesText(.footnoteCaption)
                    .foregroundStyle(Color(theme.palette.destructive))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("createBotImportError")
            }
        }
        .padding(.horizontal, PalMetrics.nameFieldHorizontalMargin)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                Task {
                    switch await TemplateFileReader.read(url) {
                    case .success(let data): await importer.begin(data)
                    case .failure(let error): importer.fail(error)
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { importer.fail(.unreadable) }
            }
        }
        .macSheet(isPresented: Binding(
            get: { importer.phase == .reviewing || importer.phase == .importing },
            set: { if !$0 { importer.reset() } }
        )) {
            TemplateReviewSheet(importer: importer) {
                guard await importer.confirm() != nil else { return }
                roster.nudge()
                router.dismissSheet()
            }
        }
    }
}

private struct TemplateReviewSheet: View {
    @Bindable var importer: TemplateImportModel
    let onImport: () async -> Void

    @Environment(\.hermesTheme) private var theme
    private var dismiss = SheetDismiss()

    var body: some View {
        SheetChrome(
            title: String(localized: "Import a template"),
            accessibilityIdentifier: "templateReviewSheet",
            leadingAccessibilityIdentifier: "templateReviewCancel",
            onLeading: { if !importer.isBusy { dismiss() } }
        ) {
            ScrollView {
                VStack(spacing: 0) {
                    if let review = importer.review {
                        content(review)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .bottom) { importButton }
        }
        .macSheetDismissDisabled(importer.isBusy)
    }

    @ViewBuilder
    private func content(_ review: TemplateReview) -> some View {
        SectionCaption(String(localized: "Name"), accessibilityIdentifier: "templateNameCaption")
            .padding(.bottom, PalMetrics.captionToCardGap)
        GroupedCard(accessibilityIdentifier: "templateNameCard") {
            TextField("", text: $importer.name, prompt: Text("Name your Bot"))
                .textFieldStyle(.plain)
                .padding(.horizontal, PalMetrics.rowInset)
                .frame(minHeight: PalMetrics.rowMinimumHeight)
                .disabled(importer.isBusy)
                .accessibilityLabel(Text("Bot name"))
                .accessibilityIdentifier("templateNameField")
        }
        if let message = nameMessage {
            Text(message)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                .padding(.top, PalMetrics.captionToCardGap)
                .accessibilityIdentifier("templateImportError")
        }
        SectionCaption(String(localized: "What's inside"), accessibilityIdentifier: "templateContentsCaption")
            .padding(.top, PalMetrics.cardGap)
            .padding(.bottom, PalMetrics.captionToCardGap)
        GroupedCard(accessibilityIdentifier: "templateContentsCard") {
            ForEach(rows(review), id: \.id) { row in
                SettingsRow.value(row.title, value: row.value, accessibilityIdentifier: "templateRow-\(row.id)")
            }
        }
        if !review.summary.isEmpty {
            CardFootnote(review.summary, accessibilityIdentifier: "templateSummary")
        }
        CardFootnote(
            String(localized: "Routines start paused. Keys and chat history are never part of a template."),
            accessibilityIdentifier: "templateFootnote")
    }

    private var nameMessage: String? {
        guard let failure = importer.failure else {
            return importer.name.isEmpty || importer.identity.isValid ? nil : String(localized: "Use letters or numbers, and a name that isn't reserved.")
        }
        return failure.message
    }

    private var importButton: some View {
        Button {
            Task { await onImport() }
        } label: {
            HStack(spacing: 8) {
                if importer.phase == .importing { ProgressView().controlSize(.small) }
                Text("Import").hermesText(.largePill)
            }
            .frame(maxWidth: .infinity)
            .frame(height: PalMetrics.createButtonHeight)
        }
        .buttonStyle(.pill())
        .disabled(!importer.canImport)
        .padding(.horizontal, 29)
        .padding(.bottom, PalMetrics.createButtonBottomPadding)
        .accessibilityIdentifier("templateImportConfirm")
    }

    private struct Row {
        let id: String
        let title: String
        let value: String
    }

    private func rows(_ review: TemplateReview) -> [Row] {
        let none = String(localized: "None")
        func list(_ names: [String]) -> String { names.isEmpty ? none : names.joined(separator: ", ") }
        let tools = review.toolsets.map { $0.isEmpty ? String(localized: "Standard set") : String(localized: "\($0.count) groups") }
        return [
            Row(id: "persona", title: String(localized: "Personality"), value: review.hasPersona ? String(localized: "Included") : none),
            Row(id: "model", title: String(localized: "Model"), value: review.model ?? String(localized: "Uses your default")),
            Row(id: "tools", title: String(localized: "Tools"), value: tools ?? String(localized: "Standard set")),
            Row(id: "skills", title: String(localized: "Skills"), value: list(review.skills)),
            Row(id: "connections", title: String(localized: "Connections"), value: list(review.connections)),
            Row(id: "routines", title: String(localized: "Routines"), value: list(review.routines)),
        ]
    }
}
