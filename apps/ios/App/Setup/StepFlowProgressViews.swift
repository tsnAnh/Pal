import PalConnect
import PalDesign
import SwiftUI

struct StepFlowSegments: View {
    let engine: StepFlowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(engine.checklist) { row in segment(row) }
            }
            .accessibilityHidden(true)
            Text(engine.positionLabel)
                .hermesText(.rowSubtitle)
                .foregroundStyle(PalTokens.textTertiary)
                .accessibilityIdentifier("stepFlowPosition")
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.bottom, PalMetrics.captionToCardGap)
    }

    private func segment(_ row: StepFlowEngine.Row) -> some View {
        Capsule()
            .fill(row.state == .upcoming ? PalTokens.control : PalTokens.toggleOn)
            .opacity(row.state == .current ? 0.55 : 1)
            .overlay {
                if row.isAutomatic {
                    Capsule().strokeBorder(PalTokens.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .frame(height: 4)
    }
}

struct StepFlowChecklist: View {
    let engine: StepFlowEngine
    let savedNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(engine.checklist) { row in checklistRow(row) }
            if let savedNote {
                Text(savedNote)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textTertiary)
                    .padding(.top, PalMetrics.screenMargin)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("stepFlowSavedNote")
            }
            Spacer(minLength: 0)
        }
        .padding(PalMetrics.screenMargin)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PalTokens.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stepFlowChecklist")
    }

    private func checklistRow(_ row: StepFlowEngine.Row) -> some View {
        HStack(spacing: 9) {
            marker(row)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .hermesText(.rowSubtitle)
                    .fontWeight(row.state == .current ? .semibold : .regular)
                    .foregroundStyle(row.state == .upcoming ? PalTokens.textTertiary : row.state == .done ? PalTokens.textSecondary : PalTokens.textPrimary)
                    .lineLimit(2)
                if row.isAutomatic {
                    Text("Pal does this")
                        .font(.system(size: 11))
                        .foregroundStyle(PalTokens.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(row.state == .current ? PalTokens.selected : Color.clear, in: RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stepFlowRow-\(row.id)")
    }

    private func marker(_ row: StepFlowEngine.Row) -> some View {
        ZStack {
            Circle()
                .fill(row.state == .done ? PalTokens.toggleOn : Color.clear)
                .overlay {
                    Circle().strokeBorder(
                        row.state == .done ? PalTokens.toggleOn : row.state == .current ? PalTokens.textPrimary : PalTokens.borderStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: row.isAutomatic ? [3, 2] : [])
                    )
                }
            if row.state == .done {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(row.number)").font(.system(size: 11)).foregroundStyle(row.state == .current ? PalTokens.textPrimary : PalTokens.textTertiary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

struct StepFlowCalmCopy {
    enum Mark {
        case spinner
        case success
        case pending
    }

    let mark: Mark
    let title: String
    let body: String
}

struct StepFlowCalmView: View {
    let copy: StepFlowCalmCopy

    private var identifier: String {
        switch copy.mark {
        case .spinner: "stepFlowWaiting"
        case .success: "stepFlowSuccess"
        case .pending: "stepFlowPending"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            switch copy.mark {
            case .spinner:
                ProgressView().controlSize(.extraLarge)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
                    .frame(width: 54, height: 54)
                    .background(PalTokens.control, in: Circle())
                    .accessibilityHidden(true)
            case .pending:
                Image(systemName: "clock")
                    .font(.system(size: 24))
                    .foregroundStyle(PalTokens.textSecondary)
                    .frame(width: 54, height: 54)
                    .background(PalTokens.control, in: Circle())
                    .accessibilityHidden(true)
            }
            Text(copy.title)
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("stepFlowCalmTitle")
            if !copy.body.isEmpty {
                Text(copy.body)
                    .hermesText(.rowTitle)
                    .foregroundStyle(PalTokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stepFlowCalmBody")
            }
        }
        .frame(maxWidth: 420)
        .padding(PalMetrics.screenMargin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct SetupHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .hermesText(.sheetTitle)
                .foregroundStyle(PalTokens.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("stepFlowTitle")
            Spacer()
            Button(role: .close, action: close)
                .buttonStyle(.glass(.regular.interactive()))
                .accessibilityIdentifier("stepFlowClose")
        }
        .padding(.horizontal, PalMetrics.screenMargin)
        .padding(.vertical, PalMetrics.captionToCardGap)
    }
}
