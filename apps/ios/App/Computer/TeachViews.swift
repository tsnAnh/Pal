import PalBotProfile
import PalDesign
import SwiftUI

struct TeachBanner: View {
    let model: TeachModel
    let surface: TeachSurface

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        if model.showsBanner {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                card(at: context.date)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("teachBanner")
        }
    }

    private func card(at date: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing * 2) {
            HStack(spacing: 8) {
                indicator
                Text(title(at: date))
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            if let detail { note(detail) }
            if model.offline { note(String(localized: "Can't reach \(model.displayName) right now. Still trying.")) }
            actions(at: date)
        }
        .padding(.horizontal, PalMetrics.rowInset)
        .padding(.vertical, PalMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.palette.groupedCard), in: shape)
        .overlay(shape.strokeBorder(Color(theme.palette.cardStroke), lineWidth: PalMetrics.separatorThickness))
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .hermesText(.rowSubtitle)
            .foregroundStyle(Color(theme.palette.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .recording:
            Circle().fill(Color(theme.palette.destructive)).frame(width: 9, height: 9)
        case .drafting:
            ProgressView().controlSize(.small).tint(Color(theme.palette.textSecondary))
        case .ready:
            Image(systemName: "lightbulb.fill").foregroundStyle(Color(theme.palette.accentBlue))
        default:
            Image(systemName: "pause.circle").foregroundStyle(Color(theme.palette.textSecondary))
        }
    }

    private func title(at date: Date) -> String {
        switch model.phase {
        case .recording:
            let left = TeachSnapshot.clock(model.snapshot?.secondsLeft(at: date.timeIntervalSince1970) ?? 0)
            return String(localized: "Teaching \(model.displayName) · \(left) left")
        case .ended:
            return model.snapshot?.ended == "limit"
                ? String(localized: "Recording stopped at the 10 minute limit")
                : String(localized: "Recording stopped when control went back")
        case .drafting:
            return String(localized: "\(model.displayName) is writing the skill…")
        case .ready:
            return String(localized: "\(model.displayName) wrote a skill for you to review")
        case .hidden, .idle:
            return ""
        }
    }

    private var detail: String? {
        switch model.phase {
        case .recording:
            model.snapshot?.waitingForBrowser == true
                ? String(localized: "Open the browser on this screen to begin. Only browser steps are recorded: no video, no sound, never what you type into password or code fields.")
                : String(localized: "\(model.displayName) is learning from what you do. Only browser steps are recorded: no video, no sound, never what you type into password or code fields.")
        case .drafting:
            String(localized: "It will appear here for your review. Nothing runs until you approve it.")
        case .ready:
            String(localized: "Nothing runs until you approve it.")
        case .ended, .hidden, .idle:
            nil
        }
    }

    @ViewBuilder
    private func actions(at date: Date) -> some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording:
                pill("Stop", .accent, "teachStop") { Task { await model.stop(discard: false) } }
            case .ended:
                pill("Create skill", .accent, "teachCreateSkill") { Task { await model.stop(discard: false) } }
                pill("Discard", .neutral, "teachDiscardRecording") { model.confirmation = .discardRecording }
            case .drafting:
                pill("Ask again", model.busy || date < model.askAgainAt ? .dimmed : .neutral, "teachAskAgain") { Task { await model.askAgain() } }
                pill("Discard", .neutral, "teachDiscardDraft") { model.confirmation = .discardDraft }
            case .ready:
                pill("Review", .accent, "teachReview") { Task { await model.openReview(from: surface) } }
                pill("Discard", .neutral, "teachDiscardDraft") { model.confirmation = .discardDraft }
            case .hidden, .idle:
                EmptyView()
            }
        }
        .disabled(model.busy && model.phase != .drafting)
    }

    private func pill(_ title: LocalizedStringResource, _ kind: PillKind, _ identifier: String, action: @escaping () -> Void) -> some View {
        PillButton(String(localized: title), kind: kind, accessibilityIdentifier: identifier, action: action)
    }
}

struct TeachReviewSheet: View {
    let model: TeachModel

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: String(localized: "Review the skill"),
            accessibilityIdentifier: "teachReviewSheet",
            leadingAccessibilityIdentifier: "teachReviewClose",
            onLeading: { if !model.busy { model.showsReview = false } }
        ) {
            content
        }
        .interactiveDismissDisabled(model.busy)
        .macSheetFrame()
    }

    @ViewBuilder
    private var content: some View {
        switch model.review {
        case .loading:
            DelayedProgressView()
                .tint(Color(theme.palette.textSecondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Loading the draft"))
                .accessibilityIdentifier("teachReviewLoading")
        case .failed:
            failure
        case .loaded(let draft):
            loaded(draft)
        }
    }

    private var failure: some View {
        GroupedCard(accessibilityIdentifier: "teachReviewFailed") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Couldn't load the draft")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                PillButton(String(localized: "Try again"), accessibilityIdentifier: "teachReviewRetry") {
                    Task { await model.openReview(from: model.surface) }
                }
            }
            .padding(.horizontal, PalMetrics.rowInset)
            .padding(.vertical, PalMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loaded(_ draft: TeachDraft) -> some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            ScrollView {
                VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
                    CardFootnote(
                        String(localized: "\(model.displayName) learned this from your demonstration. It stays off until you approve it."),
                        accessibilityIdentifier: "teachReviewIntro"
                    )
                    draftBody(draft)
                    notes(draft)
                    if let error = model.reviewError {
                        Text(error)
                            .hermesText(.rowSubtitle)
                            .foregroundStyle(Color(theme.palette.destructive))
                            .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                            .accessibilityIdentifier("teachReviewError")
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack {
                PillButton(String(localized: "Discard"), size: .large, accessibilityIdentifier: "teachReviewDiscard") {
                    model.confirmation = .discardDraft
                }
                Spacer(minLength: 0)
                PillButton(
                    String(localized: "Approve"),
                    kind: draft.canApprove ? .accent : .dimmed,
                    size: .large,
                    isBusy: model.busy,
                    accessibilityIdentifier: "teachReviewApprove"
                ) {
                    model.confirmation = .approve
                }
            }
            .padding(.horizontal, PalMetrics.screenMargin)
            .padding(.bottom, PalMetrics.screenMargin)
        }
    }

    @ViewBuilder
    private func draftBody(_ draft: TeachDraft) -> some View {
        if let body = draft.content, draft.isReady {
            GroupedCard(accessibilityIdentifier: "teachDraftContent") {
                Text(body)
                    .font(.system(size: ConnectRowMetrics.subtitleSize, design: .monospaced))
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PalMetrics.rowInset)
                    .padding(.vertical, PalMetrics.rowVerticalPadding)
            }
        } else {
            PlaceholderRow(String(localized: "The skill hasn't been written yet."), accessibilityIdentifier: "teachDraftPlaceholder")
        }
    }

    @ViewBuilder
    private func notes(_ draft: TeachDraft) -> some View {
        CardFootnote(String(localized: "Passwords, codes and card numbers you typed were never recorded."), accessibilityIdentifier: "teachNotePrivacy")
        if draft.truncated {
            CardFootnote(
                String(localized: "The recording hit its size limit, so the end of the workflow may be missing."),
                accessibilityIdentifier: "teachNoteTruncated"
            )
        }
        if !draft.extraFiles.isEmpty {
            Text("This draft also contains other files (\(draft.extraFiles.joined(separator: ", "))). Only the skill text can be reviewed here, so it can't be approved. Discard it and teach again.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .padding(.horizontal, PalMetrics.screenMargin + PalMetrics.rowInset - 3)
                .accessibilityIdentifier("teachNoteExtraFiles")
        }
    }
}

private struct TeachPresentation: ViewModifier {
    let model: TeachModel
    let surface: TeachSurface

    private var active: Bool { model.surface == surface }

    func body(content: Content) -> some View {
        content
            .onAppear { model.surface = surface }
            .task(id: TeachObserveKey(kick: model.kick, active: active)) {
                guard active else { return }
                await model.observe()
            }
            .toast(Binding(get: { active ? model.toast : nil }, set: { if active { model.toast = $0 } }), accessibilityIdentifier: "teachToast")
            .sheet(isPresented: Binding(get: { active && model.showsReview }, set: { if !$0 { model.showsReview = false } })) {
                TeachReviewSheet(model: model)
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(get: { active && model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
                titleVisibility: .visible
            ) {
                switch model.confirmation {
                case .approve:
                    Button("Approve") { Task { await model.approve() } }
                        .accessibilityIdentifier("teachApproveConfirm")
                case .discardDraft:
                    Button("Discard", role: .destructive) { Task { await model.discardDraft() } }
                        .accessibilityIdentifier("teachDiscardDraftConfirm")
                case .discardRecording:
                    Button("Discard", role: .destructive) { Task { await model.stop(discard: true) } }
                        .accessibilityIdentifier("teachDiscardRecordingConfirm")
                case nil:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage)
            }
    }

    private var confirmationTitle: Text {
        switch model.confirmation {
        case .approve: Text("Turn on this skill?")
        case .discardDraft: Text("Discard this draft?")
        case .discardRecording: Text("Discard this recording?")
        case nil: Text("")
        }
    }

    private var confirmationMessage: String {
        switch model.confirmation {
        case .approve: String(localized: "\(model.displayName) will start using this skill. It applies to \(model.displayName) only.")
        case .discardDraft: String(localized: "The draft skill and the recording are deleted. This can't be undone.")
        case .discardRecording: String(localized: "The recording is deleted and no skill is created.")
        case nil: ""
        }
    }
}

extension View {
    func teachPresentations(_ model: TeachModel, surface: TeachSurface) -> some View {
        modifier(TeachPresentation(model: model, surface: surface))
    }
}
