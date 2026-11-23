import PalConnect
import PalDesign
import SwiftUI

struct StepFlowSegments: View {
    let engine: StepFlowEngine
    let layout: StepFlowLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(engine.checklist) { row in segment(row) }
            }
            .accessibilityHidden(true)
            if layout == .stacked {
                Text(engine.positionLabel)
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textTertiary)
                    .accessibilityIdentifier("stepFlowPosition")
            }
        }
        .padding(.horizontal, layout == .stepper ? StepperMetrics.barMargin : PalMetrics.screenMargin)
        .padding(.bottom, layout == .stepper ? 0 : PalMetrics.captionToCardGap)
    }

    private func segment(_ row: StepFlowEngine.Row) -> some View {
        Capsule()
            .fill(fill(row.state))
            .opacity(layout != .stepper && row.state == .current ? 0.55 : 1)
            .overlay {
                if row.isAutomatic {
                    Capsule().strokeBorder(PalTokens.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .frame(height: 4)
    }

    private func fill(_ state: StepFlowEngine.RowState) -> Color {
        switch state {
        case .done: PalTokens.textSecondary
        case .current: PalTokens.textPrimary
        case .upcoming: PalTokens.control
        }
    }
}

struct StepFlowChecklist: View {
    let engine: StepFlowEngine
    let savedNote: String?

    var body: some View {
        MacOverflowScroll {
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
        }
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
                .fill(row.state == .done ? PalTokens.inverseFill : Color.clear)
                .overlay {
                    Circle().strokeBorder(
                        row.state == .done ? PalTokens.inverseFill : row.state == .current ? PalTokens.textPrimary : PalTokens.borderStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: row.isAutomatic ? [3, 2] : [])
                    )
                }
            if row.state == .done {
                PalIcon("checkmark", ink: .onInverseFill).font(.system(size: 10, weight: .bold))
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
                PalIcon("checkmark", ink: .success)
                    .font(.system(size: 24))
                    .frame(width: 54, height: 54)
                    .background(PalTokens.control, in: Circle())
                    .accessibilityHidden(true)
            case .pending:
                PalIcon("clock", ink: .secondary)
                    .font(.system(size: 24))
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

struct SetupChrome<Content: View>: View {
    let title: String
    let app: ConnectApp?
    let progress: StepFlowEngine?
    let accessibilityIdentifier: String
    let closeIdentifier: String
    let close: () -> Void
    private let content: Content

    @Environment(\.sheetChromeHostedInNavigation) private var pushed

    init(
        title: String, app: ConnectApp? = nil, progress: StepFlowEngine? = nil, accessibilityIdentifier: String,
        closeIdentifier: String = "stepFlowClose", close: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.app = app
        self.progress = progress
        self.accessibilityIdentifier = accessibilityIdentifier
        self.closeIdentifier = closeIdentifier
        self.close = close
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        SheetChrome(
            leading: pushed ? .back : .close,
            headerStyle: .stepper,
            accessibilityIdentifier: accessibilityIdentifier,
            leadingAccessibilityIdentifier: pushed ? "stepFlowBack" : closeIdentifier,
            onLeading: close,
            trailing: { StepperHeaderTitle(title: title, app: app, progress: progress, identifier: "\(accessibilityIdentifier)-title") },
            content: { content }
        )
        #else
        SheetChrome(
            title: title,
            leading: pushed ? .back : .close,
            accessibilityIdentifier: accessibilityIdentifier,
            leadingAccessibilityIdentifier: pushed ? "stepFlowBack" : closeIdentifier,
            onLeading: close,
            content: { content }
        )
        #endif
    }
}

private struct StepperHeaderTitle: View {
    let title: String
    let app: ConnectApp?
    let progress: StepFlowEngine?
    let identifier: String

    var body: some View {
        HStack(spacing: 10) {
            if let app {
                ConnectorLogoTile(app: app)
                    .scaleEffect(StepperMetrics.logoSize / ConnectRowMetrics.tileSize)
                    .frame(width: StepperMetrics.logoSize, height: StepperMetrics.logoSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .hermesText(.sheetTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(PalTokens.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier)
                if let progress { position(progress) }
            }
        }
    }

    private func position(_ engine: StepFlowEngine) -> some View {
        HStack(spacing: 0) {
            Text(engine.positionLabel)
                .accessibilityIdentifier("stepFlowPosition")
            if engine.current.isAutomatic {
                Text(" · Pal does this part")
                    .accessibilityIdentifier("stepFlowPositionAutomatic")
            }
        }
        .hermesText(.rowSubtitle)
        .foregroundStyle(PalTokens.textTertiary)
        .lineLimit(1)
    }
}
