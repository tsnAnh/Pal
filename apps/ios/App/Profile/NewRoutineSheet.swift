import HermesBotProfile
import HermesDesign
import SwiftUI

struct NewRoutineSheet: View {
    @Bindable var model: NewRoutineModel
    let onClose: () -> Void

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        SheetChrome(
            title: String(localized: "New Routine"),
            accessibilityIdentifier: "newRoutineSheet",
            onLeading: onClose,
            trailing: {
                PillButton(
                    String(localized: "Save"),
                    kind: model.canSave ? .accent : .dimmed,
                    isBusy: model.isSaving,
                    accessibilityIdentifier: "newRoutineSave"
                ) {
                    Task { if await model.save() { onClose() } }
                }
            },
            content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        field(String(localized: "Name"), text: $model.title, prompt: String(localized: "Morning brief"), identifier: "newRoutineTitle")
                        SectionCaption(String(localized: "What should it do?"), accessibilityIdentifier: "newRoutinePromptCaption")
                            .padding(.top, HermesMetrics.cardGap)
                            .padding(.bottom, HermesMetrics.captionToCardGap)
                        promptField
                        SectionCaption(String(localized: "When should it run?"), accessibilityIdentifier: "newRoutineScheduleCaption")
                            .padding(.top, HermesMetrics.cardGap)
                            .padding(.bottom, HermesMetrics.captionToCardGap)
                        field(String(localized: "Schedule"), text: $model.schedule, prompt: String(localized: "weekdays at 8:30 AM"), identifier: "newRoutineSchedule")
                        previewLine
                            .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset)
                            .padding(.top, 10)
                        if let failure = model.failure {
                            Text(failure)
                                .hermesText(.rowSubtitle)
                                .foregroundStyle(Color(theme.palette.destructive))
                                .padding(.horizontal, HermesMetrics.screenMargin + HermesMetrics.rowInset)
                                .padding(.top, 10)
                                .accessibilityIdentifier("newRoutineFailure")
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        )
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, identifier: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textInputAutocapitalization(identifier == "newRoutineSchedule" ? .never : .sentences)
            .autocorrectionDisabled(identifier == "newRoutineSchedule")
            .padding(.horizontal, HermesMetrics.rowInset)
            .frame(height: HermesMetrics.rowMinimumHeight)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, HermesMetrics.screenMargin)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
    }

    private var promptField: some View {
        TextField("", text: $model.prompt, prompt: Text("Summarize what happened overnight"), axis: .vertical)
            .lineLimit(3...8)
            .padding(.horizontal, HermesMetrics.rowInset)
            .padding(.vertical, 14)
            .frame(minHeight: HermesMetrics.rowMinimumHeight, alignment: .topLeading)
            .background(Color(theme.palette.groupedCard), in: RoundedRectangle(cornerRadius: HermesMetrics.cardRadius, style: .continuous))
            .padding(.horizontal, HermesMetrics.screenMargin)
            .accessibilityLabel(Text("Prompt"))
            .accessibilityIdentifier("newRoutinePrompt")
    }

    @ViewBuilder
    private var previewLine: some View {
        switch model.preview {
        case .idle:
            Text("Try “every day at 9am” or “weekdays at 8:30 AM”.")
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.textSecondary))
        case .checking:
            ProgressView().controlSize(.small)
        case .accepted(let preview):
            VStack(alignment: .leading, spacing: 4) {
                Text("Accepted as \(preview.acceptedAs)")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(Color(theme.palette.textPrimary))
                    .accessibilityIdentifier("newRoutineAcceptedAs")
                if let next = preview.nextRun {
                    Text("Next run \(next.formatted(date: .abbreviated, time: .shortened))")
                        .hermesText(.rowSubtitle)
                        .foregroundStyle(Color(theme.palette.textSecondary))
                }
            }
        case .refused(let message):
            Text(message)
                .hermesText(.rowSubtitle)
                .foregroundStyle(Color(theme.palette.destructive))
                .accessibilityIdentifier("newRoutineRefused")
        }
    }
}
