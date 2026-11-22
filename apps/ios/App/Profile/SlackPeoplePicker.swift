import PalBotProfile
import PalDesign
import PalProtocol
import SwiftUI

struct SlackPeoplePicker: View {
    @Bindable var search: ChatPeopleSearchModel
    let name: String
    let workspace: String
    let close: () -> Void

    var body: some View {
        SheetChrome(
            title: String(localized: "Who can talk to \(name)"),
            accessibilityIdentifier: "slackPeoplePicker",
            leadingAccessibilityIdentifier: "slackPeopleClose",
            onLeading: close,
            trailing: {
                Button {
                    Task { if await search.commit() { close() } }
                } label: {
                    HStack(spacing: 6) {
                        if search.isCommitting { ProgressView().controlSize(.small) }
                        Text("Done")
                    }
                }
                .glassButtonStyle(prominent: true)
                .disabled(search.isCommitting || search.phase != .ready)
                .accessibilityIdentifier("slackPeopleDone")
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: PalMetrics.screenMargin) {
                        field
                        if search.phase == .ready, !search.picked.isEmpty || search.query.isEmpty {
                            Text("\(search.picked.count) picked. They can chat with \(name); changes still wait for your OK.")
                                .hermesText(.rowSubtitle)
                                .foregroundStyle(PalTokens.textTertiary)
                                .accessibilityIdentifier("slackPeopleCount")
                        }
                        results
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(PalMetrics.screenMargin)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        )
        .task { await search.start() }
    }

    private var field: some View {
        ClearGlassSearchField(
            text: $search.query, prompt: String(localized: "Search people in \(workspace)"),
            accessibilityLabel: String(localized: "Search people"), accessibilityIdentifier: "slackPeopleSearch", height: 44, fontSize: 15
        )
    }

    @ViewBuilder
    private var results: some View {
        switch search.phase {
        case .loading:
            SlackCard {
                ForEach(0..<5, id: \.self) { index in
                    if index > 0 { PalHairline() }
                    HStack(spacing: 12) {
                        Circle().fill(PalTokens.control).frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(PalTokens.control).frame(width: 140, height: 12)
                            Capsule().fill(PalTokens.control).frame(width: 80, height: 9)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(PalMetrics.screenMargin)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("slackPeopleLoading")
        case .failed:
            message(
                symbol: "person.2", title: String(localized: "Couldn't load people from \(workspace)"),
                detail: String(localized: "Check your connection and try again. People you already picked are kept."),
                identifier: "slackPeopleFailed", retry: true
            )
        case .ready where search.people.isEmpty:
            message(
                symbol: "magnifyingglass", title: String(localized: "No one named \"\(search.query)\""),
                detail: String(localized: "Only people in \(workspace) show up here."), identifier: "slackPeopleEmpty", retry: false
            )
        case .ready:
            SlackCard {
                ForEach(Array(search.people.enumerated()), id: \.element.id) { offset, person in
                    if offset > 0 { PalHairline() }
                    row(person)
                        .task { await search.loadMoreIfNeeded(after: person) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("slackPeopleList")
        }
    }

    private func row(_ person: ChatPersonWire) -> some View {
        let isPicked = search.isPicked(person.id)
        return Button { search.toggle(person) } label: {
            HStack(spacing: 12) {
                PersonBadge(name: person.shownName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.shownName).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary).lineLimit(1)
                    Text("@\(person.name)").hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PalIcon("checkmark", ink: .primary).opacity(isPicked ? 1 : 0).accessibilityHidden(true)
            }
            .padding(PalMetrics.screenMargin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("slackPerson-\(person.id)")
    }

    private func message(symbol: String, title: String, detail: String, identifier: String, retry: Bool) -> some View {
        VStack(spacing: 10) {
            PalIcon(symbol, ink: .tertiary).font(.system(size: 30, weight: .light)).accessibilityHidden(true)
            Text(title).hermesText(.rowTitle).foregroundStyle(PalTokens.textPrimary).multilineTextAlignment(.center)
            Text(detail).hermesText(.rowSubtitle).foregroundStyle(PalTokens.textTertiary).multilineTextAlignment(.center)
            if retry {
                Button { Task { await search.retry() } } label: { Label("Try again", palIcon: "arrow.clockwise") }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("slackPeopleRetry")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
