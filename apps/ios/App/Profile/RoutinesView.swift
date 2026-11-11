import PalBotProfile
import PalDesign
import SwiftUI

struct RoutinesView: View {
    @State private var model: RoutinesModel

    @Environment(\.hermesTheme) private var theme
    @State private var creation: NewRoutineModel?

    init(model: RoutinesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                content
            }
            .padding(.top, RoutinesMetrics.topPadding)
            .padding(.bottom, 32)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(theme.palette.sheetBackground).ignoresSafeArea())
        .accessibilityIdentifier("routinesScreen")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Routines")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("routinesTitle")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .trailingBar) {
                Button { creation = model.creationModel() } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("New Routine"))
                .accessibilityIdentifier("routinesNewButton")
                .tint(.primary)
            }
        }
        .toolbarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .toast($model.toast)
        .sheet(item: $creation) { created in
            NewRoutineSheet(model: created) { creation = nil }
                .macSheetFrame()
        }
        .confirmationDialog(
            Text("Delete this routine?"),
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingRemoval
        ) { routine in
            Button("Delete", role: .destructive) { Task { await model.remove(routine) } }
                .accessibilityIdentifier("routineDeleteConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { routine in
            Text("\(routine.title) won't run again.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .padding(.top, 80)
                .accessibilityIdentifier("routinesLoading")
        case .failed:
            RoutinesNotice(
                title: String(localized: "Couldn't load routines"),
                message: String(localized: "Check your connection and try again."),
                actionTitle: String(localized: "Try again"),
                action: { Task { await model.load() } },
                accessibilityIdentifier: "routinesFailed"
            )
        case .ready where model.routines.isEmpty:
            RoutinesNotice(
                title: String(localized: "No routines yet"),
                message: String(localized: "A routine runs a prompt on a schedule and delivers the result to your chat."),
                actionTitle: String(localized: "New Routine"),
                action: { creation = model.creationModel() },
                accessibilityIdentifier: "routinesEmpty"
            )
        case .ready:
            GroupedCard(accessibilityIdentifier: "routinesCard") {
                ForEach(model.routines) { routine in
                    SwipeActionRow(
                        actionTitle: String(localized: "Delete"),
                        accessibilityIdentifier: "routine-\(routine.id)",
                        action: { model.pendingRemoval = routine }
                    ) {
                        RoutineRow(routine: routine, isOn: Binding(
                            get: { model.routines.first { $0.id == routine.id }?.isEnabled ?? false },
                            set: { enabled in Task { await model.setEnabled(enabled, for: routine) } }
                        ))
                    }
                }
            }
        }
    }
}

extension NewRoutineModel: Identifiable {}

private struct RoutineRow: View {
    let routine: Routine
    @Binding var isOn: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: PalMetrics.rowTextSpacing) {
                Text(routine.title)
                    .hermesText(.rowTitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .lineLimit(2)
                Text(routine.caption())
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(routine.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(PalToggleStyle())
                .accessibilityLabel(Text(routine.title))
                .accessibilityIdentifier("routineToggle-\(routine.id)")
        }
        .padding(.horizontal, PalMetrics.rowInset)
        .padding(.vertical, RoutinesMetrics.rowVerticalPadding)
        .frame(minHeight: RoutinesMetrics.rowHeight)
        .contentShape(Rectangle())
    }
}

private struct RoutinesNotice: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
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
            PillButton(actionTitle, accessibilityIdentifier: "\(accessibilityIdentifier)-action", action: action)
                .padding(.top, 8)
        }
        .padding(.horizontal, 48)
        .padding(.top, 96)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum RoutinesMetrics {
    static let topPadding: CGFloat = 12
    static let rowHeight: CGFloat = 65
    static let rowVerticalPadding: CGFloat = 12
}
