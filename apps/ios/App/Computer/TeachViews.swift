import HermesBotProfile
import HermesDesign
import SwiftUI

struct TeachBanner: View {
    let model: TeachModel
    let surface: TeachSurface

    var body: some View {
        if model.showsBanner {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        indicator
                        Text(title(at: context.date))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                    if model.offline {
                        Text("Can't reach \(model.displayName) right now. Still trying.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    actions(at: context.date)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("teachBanner")
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .recording:
            Circle().fill(.red).frame(width: 9, height: 9)
        case .drafting:
            ProgressView().controlSize(.small)
        case .ready:
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
        default:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
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
                Button("Stop") { Task { await model.stop(discard: false) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("teachStop")
            case .ended:
                Button("Create skill") { Task { await model.stop(discard: false) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("teachCreateSkill")
                Button("Discard", role: .destructive) { model.confirmation = .discardRecording }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("teachDiscardRecording")
            case .drafting:
                Button("Ask again") { Task { await model.askAgain() } }
                    .buttonStyle(.bordered)
                    .disabled(model.busy || date < model.askAgainAt)
                    .accessibilityIdentifier("teachAskAgain")
                Button("Discard", role: .destructive) { model.confirmation = .discardDraft }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("teachDiscardDraft")
            case .ready:
                Button("Review") { Task { await model.openReview(from: surface) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("teachReview")
                Button("Discard", role: .destructive) { model.confirmation = .discardDraft }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("teachDiscardDraft")
            case .hidden, .idle:
                EmptyView()
            }
        }
        .disabled(model.busy && model.phase != .drafting)
    }
}

struct TeachReviewSheet: View {
    let model: TeachModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Review the skill"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { model.showsReview = false }
                            .disabled(model.busy)
                            .accessibilityIdentifier("teachReviewClose")
                    }
                }
        }
        .interactiveDismissDisabled(model.busy)
        .macSheetFrame()
    }

    @ViewBuilder
    private var content: some View {
        switch model.review {
        case .loading:
            ProgressView("Loading the draft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("teachReviewLoading")
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load the draft", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try again") { Task { await model.openReview(from: model.surface) } }
                    .accessibilityIdentifier("teachReviewRetry")
            }
        case .loaded(let draft):
            loaded(draft)
        }
    }

    private func loaded(_ draft: TeachDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.displayName) learned this from your demonstration. It stays off until you approve it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let body = draft.content, draft.isReady {
                ScrollView {
                    Text(body)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("teachDraftContent")
            } else {
                Text("The skill hasn't been written yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            notes(draft)
            if let error = model.reviewError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("teachReviewError")
            }
            HStack {
                Button("Discard", role: .destructive) { model.confirmation = .discardDraft }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("teachReviewDiscard")
                Spacer(minLength: 0)
                Button {
                    model.confirmation = .approve
                } label: {
                    if model.busy { ProgressView().controlSize(.small) } else { Text("Approve") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !draft.canApprove)
                .accessibilityIdentifier("teachReviewApprove")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func notes(_ draft: TeachDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Passwords, codes and card numbers you typed were never recorded.")
            if draft.truncated {
                Text("The recording hit its size limit, so the end of the workflow may be missing.")
            }
            if !draft.extraFiles.isEmpty {
                Text("This draft also contains other files (\(draft.extraFiles.joined(separator: ", "))). Only the skill text can be reviewed here, so it can't be approved. Discard it and teach again.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
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
