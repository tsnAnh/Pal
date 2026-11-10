import HermesBotProfile
import HermesDesign
import QuickLook
import SwiftUI

struct LibraryView: View {
    @State private var model: LibraryModel
    private let showsChrome: Bool
    private let filters: [LibraryFilter]

    @Environment(\.hermesTheme) private var theme

    init(model: LibraryModel, showsChrome: Bool = true, filters: [LibraryFilter] = LibraryFilter.allCases) {
        _model = State(initialValue: model)
        self.showsChrome = showsChrome
        self.filters = filters
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                chips
                content
            }
            .padding(.bottom, 32)
            #if os(macOS)
            .padding(.leading, showsChrome ? 0 : 12)
            .padding(.trailing, showsChrome ? 0 : 15)
            #endif
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background {
            if showsChrome { Color(theme.palette.sheetBackground).ignoresSafeArea() }
        }
        .accessibilityIdentifier("libraryScreen")
        .toolbar {
            if showsChrome {
                ToolbarItem(placement: .principal) {
                    Text("Library")
                        .hermesText(.sheetTitle)
                        .foregroundStyle(Color(theme.palette.textPrimary))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("libraryTitle")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
        .inAppBrowser(url: $model.safariURL)
        .quickLookPreview($model.previewURL)
        .onChange(of: model.previewURL) { model.cleanUpPreview() }
        .alert(Text("This item can't be opened right now"), isPresented: Binding(get: { model.previewFailed }, set: { if !$0 { model.dismissPreviewFailure() } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var chips: some View {
        #if os(macOS)
        if showsChrome { standardChips } else { MacLibraryChips(filters: filters, selection: $model.filter) }
        #else
        standardChips
        #endif
    }

    private var standardChips: some View {
        FilterChipBar(
            items: filters.map { FilterChipItem(id: $0, title: $0.title) },
            selection: $model.filter,
            accessibilityIdentifier: "libraryFilter"
        )
        .padding(.bottom, LibraryMetrics.chipsToContent)
    }

    @ViewBuilder
    private var readySections: some View {
        #if os(macOS)
        if showsChrome {
            ForEach(model.sections) { section in standardSection(section) }
        } else {
            ForEach(MacLibraryGroup.groups(model.entries)) { group in macSection(group) }
        }
        #else
        ForEach(model.sections) { section in standardSection(section) }
        #endif
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
            readySections
            if model.isIndexing || model.isLoadingMore {
                ProgressView()
                    .padding(.top, 24)
                    .accessibilityIdentifier("libraryIndexing")
            }
        }
    }
}

extension LibraryView {
    @ViewBuilder
    fileprivate func standardSection(_ section: LibrarySection) -> some View {
        SectionCaption(section.id.title, accessibilityIdentifier: "librarySection-\(section.id.rawValue)")
            .padding(.top, LibraryMetrics.sectionGap)
            .padding(.bottom, HermesMetrics.captionToCardGap)
        GroupedCard(accessibilityIdentifier: "libraryCard-\(section.id.rawValue)") {
            ForEach(section.entries) { entry in
                LibraryRow(entry: entry, model: model)
            }
        }
    }

    #if os(macOS)
    fileprivate func macSection(_ group: MacLibraryGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(group.title)
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.horizontal, 11)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("librarySection-\(group.id)")
            VStack(spacing: 0) {
                ForEach(group.entries) { entry in
                    MacLibraryRow(entry: entry, model: model)
                }
            }
            .frame(maxWidth: .infinity)
            .background(PalTokens.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("libraryCard-\(group.id)")
        }
        .padding(.top, 24)
    }
    #endif
}

#if os(macOS)
struct MacLibraryGroup: Identifiable {
    let id: String
    let title: String
    let entries: [LibraryEntry]

    static func groups(_ entries: [LibraryEntry], now: Date = Date(), calendar: Calendar = .current) -> [MacLibraryGroup] {
        let today = entries.filter { calendar.isDate($0.occurredAt, inSameDayAs: now) }
        let older = entries.filter { !calendar.isDate($0.occurredAt, inSameDayAs: now) }
        return [
            today.isEmpty ? nil : MacLibraryGroup(id: "today", title: String(localized: "Today"), entries: today),
            older.isEmpty ? nil : MacLibraryGroup(id: "older", title: String(localized: "Older"), entries: older),
        ].compactMap { $0 }
    }
}

private struct MacLibraryChips: View {
    let filters: [LibraryFilter]
    @Binding var selection: LibraryFilter

    var body: some View {
        HStack(spacing: 4) {
            ForEach(filters, id: \.self) { filter in
                let isSelected = selection == filter
                Button { selection = filter } label: {
                    Text(filter.title)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? PalTokens.inverseText : PalTokens.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(isSelected ? PalTokens.inverseFill : PalTokens.elevated, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("libraryFilter-\(filter.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryFilter")
    }
}

private struct MacLibraryRow: View {
    let entry: LibraryEntry
    let model: LibraryModel

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
        HStack(spacing: 8) {
            LibraryIcon(entry: entry, model: model, size: 20, glyph: 12)
                .frame(width: 20, height: 20)
            Text(entry.title)
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if model.preparingEntryID == entry.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 33)
        .contentShape(Rectangle())
        .help(entry.subtitle())
        .onAppear { model.loadMoreIfNeeded(after: entry) }
    }
}
#endif

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
    var size = LibraryMetrics.iconSize
    var glyph: CGFloat = 20

    @Environment(\.hermesTheme) private var theme
    @State private var thumbnail: PlatformImage?

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
        if let url = entry.url, let image = FaviconCache.shared.image(for: url, pointSize: size) {
            Image(platformImage: image)
        } else {
            symbol("globe")
        }
    }

    @ViewBuilder
    private var mediaIcon: some View {
        if let thumbnail {
            Image(platformImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            symbol("photo")
                .task(id: entry.id) {
                    guard let data = await model.thumbnail(for: entry),
                          let image = await PlatformImage.thumbnail(from: data, side: 96)
                    else { return }
                    thumbnail = image
                }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: glyph, weight: .light))
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
    static let rowHeight: CGFloat = 65
    static let rowVerticalPadding: CGFloat = 12
    static let chipsToContent: CGFloat = 4
    static let sectionGap: CGFloat = 22
}
