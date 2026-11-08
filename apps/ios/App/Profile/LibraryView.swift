import HermesBotProfile
import HermesDesign
import QuickLook
import SafariServices
import SwiftUI

struct LibraryView: View {
    @State private var model: LibraryModel

    @Environment(\.hermesTheme) private var theme

    init(model: LibraryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                FilterChipBar(
                    items: LibraryFilter.allCases.map { FilterChipItem(id: $0, title: $0.title) },
                    selection: $model.filter,
                    accessibilityIdentifier: "libraryFilter"
                )
                .padding(.bottom, LibraryMetrics.chipsToContent)
                content
            }
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("libraryScreen")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Library")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("libraryTitle")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
        .fullScreenCover(item: Binding(get: { model.safariURL.map(SafariTarget.init) }, set: { if $0 == nil { model.safariURL = nil } })) { target in
            SafariView(url: target.url).ignoresSafeArea()
        }
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { model.cleanUpPreview() }
        .alert(Text("This item can't be opened right now"), isPresented: Binding(get: { model.previewFailed }, set: { if !$0 { model.dismissPreviewFailure() } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .padding(.top, 80)
                .accessibilityIdentifier("libraryLoading")
        case .failed:
            LibraryNotice(
                title: String(localized: "Couldn't load your library"),
                message: String(localized: "Check your connection and try again."),
                actionTitle: String(localized: "Try again"),
                action: model.retry,
                accessibilityIdentifier: "libraryFailed"
            )
        case .ready where model.isEmpty:
            LibraryNotice(
                title: model.isIndexing ? String(localized: "Building your library") : String(localized: "Nothing here yet"),
                message: String(localized: "Links, images and files from your chats with this Bot show up here."),
                accessibilityIdentifier: "libraryEmpty"
            )
        case .ready:
            ForEach(model.sections) { section in
                SectionCaption(section.id.title, accessibilityIdentifier: "librarySection-\(section.id.rawValue)")
                    .padding(.top, LibraryMetrics.sectionGap)
                    .padding(.bottom, HermesMetrics.captionToCardGap)
                GroupedCard(separatorInset: LibraryMetrics.separatorInset, accessibilityIdentifier: "libraryCard-\(section.id.rawValue)") {
                    ForEach(section.entries) { entry in
                        LibraryRow(entry: entry, model: model)
                    }
                }
            }
            if model.isIndexing || model.isLoadingMore {
                ProgressView()
                    .padding(.top, 24)
                    .accessibilityIdentifier("libraryIndexing")
            }
        }
    }
}

private struct SafariTarget: Identifiable {
    let url: URL

    var id: URL { url }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let model: LibraryModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if entry.isOpenable {
            Button { model.open(entry) } label: { rowContent }
                .buttonStyle(.plain)
                .accessibilityIdentifier("libraryRow-\(entry.id)")
                .accessibilityValue(Text(entry.kind.rawValue))
        } else {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("libraryRow-\(entry.id)")
                .accessibilityValue(Text(entry.kind.rawValue))
        }
    }

    private var rowContent: some View {
        HStack(spacing: LibraryMetrics.iconToText) {
            LibraryIcon(entry: entry, model: model)
                .frame(width: LibraryMetrics.iconSize, height: LibraryMetrics.iconSize)
            VStack(alignment: .leading, spacing: HermesMetrics.rowTextSpacing) {
                Text(entry.title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(1)
                Text(entry.subtitle())
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.preparingEntryID == entry.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.leading, LibraryMetrics.leadingInset)
        .padding(.trailing, HermesMetrics.rowInset)
        .padding(.vertical, LibraryMetrics.rowVerticalPadding)
        .frame(minHeight: LibraryMetrics.rowHeight)
        .contentShape(Rectangle())
        .onAppear { model.loadMoreIfNeeded(after: entry) }
    }
}

private struct LibraryIcon: View {
    let entry: LibraryEntry
    let model: LibraryModel

    @Environment(\.hermesTheme) private var theme
    @State private var thumbnail: UIImage?

    var body: some View {
        switch entry.kind {
        case .link:
            linkIcon
        case .media:
            mediaIcon
        case .file:
            symbol("doc")
        }
    }

    @ViewBuilder
    private var linkIcon: some View {
        if let url = entry.url, let image = FaviconCache.shared.image(for: url, pointSize: LibraryMetrics.iconSize) {
            Image(uiImage: image)
        } else {
            symbol("globe")
        }
    }

    @ViewBuilder
    private var mediaIcon: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: LibraryMetrics.iconSize, height: LibraryMetrics.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: LibraryMetrics.iconSize * 0.22, style: .continuous))
        } else {
            symbol("photo")
                .task(id: entry.id) {
                    guard let data = await model.thumbnail(for: entry),
                          let image = await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 96, height: 96))
                    else { return }
                    thumbnail = image
                }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(Color(theme.palette.textSecondary))
    }
}

private struct LibraryNotice: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    let accessibilityIdentifier: String

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .hermesText(.rowTitle)
                .foregroundStyle(Color(theme.palette.textPrimary))
            Text(message)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                PillButton(actionTitle, accessibilityIdentifier: "\(accessibilityIdentifier)-action", action: action)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 96)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum LibraryMetrics {
    static let iconSize: CGFloat = 24
    static let leadingInset: CGFloat = 18
    static let iconToText: CGFloat = 10
    static let separatorInset: CGFloat = leadingInset + iconSize + iconToText
    static let rowHeight: CGFloat = 65
    static let rowVerticalPadding: CGFloat = 12
    static let chipsToContent: CGFloat = 4
    static let sectionGap: CGFloat = 22
}
