#if os(macOS)
import PalConnect
import PalDesign
import PalLocalEngine
import SwiftUI

struct LocalEngineSetupPanel: View {
    let engine: LocalEngineModel

    var body: some View {
        Group {
            switch engine.state {
            case .installing(let progress):
                installing(progress)
            case .failed(let failure):
                failed(failure)
            case .ready where engine.isSigningIn:
                done
            default:
                intro
            }
        }
        .animation(.snappy(duration: 0.2), value: engine.isInstalling)
    }

    private var intro: some View {
        PanelColumn {
            VStack(spacing: 0) {
                PanelHero(symbol: "laptopcomputer", ink: .primary)
                Text("Run Pal on this Mac")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("localEngineIntroTitle")
                    .padding(.top, 14)
                MacCard(identifier: "localEngineFacts") {
                    FactRow(symbol: "folder", text: String(localized: "Installs in your home folder"))
                    FactRow(symbol: "arrow.triangle.2.circlepath", text: String(localized: "Keeps running in the background while you’re logged in"))
                    FactRow(symbol: "arrow.down.to.line", text: String(localized: "Needs internet for the download, about 2 GB"))
                }
                .padding(.top, 20)
            }
        } action: {
            PanelButton(title: String(localized: "Install"), kind: .primary, identifier: "localEngineInstall") { engine.install() }
        }
    }

    private func installing(_ progress: InstallProgress) -> some View {
        PanelColumn {
            VStack(spacing: 0) {
                Text("Installing Pal")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("localEngineInstallingTitle")
                MacCard(identifier: "localEngineSteps") {
                    ForEach(InstallStep.allCases, id: \.self) { step in
                        StepRow(step: step, status: progress.status(of: step))
                    }
                }
                .padding(.top, 16)
                elapsed
                    .padding(.top, 12)
            }
        } action: {
            PanelButton(title: String(localized: "Cancel"), kind: .secondary, identifier: "localEngineCancel") { engine.cancelInstall() }
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        if let start = engine.installStartedAt {
            Text("\(Text(timerInterval: start...Date.distantFuture, countsDown: false, showsHours: false)) elapsed. This can take a few minutes.")
                .font(.system(size: 12))
                .foregroundStyle(PalTokens.textTertiary)
                .accessibilityIdentifier("localEngineElapsed")
        }
    }

    private func failed(_ failure: EngineFailure) -> some View {
        StatusBlock(
            status: SetupStatus(
                title: failure.title, reason: failure.reason, actionTitle: failure.actionTitle, code: failure.code, trace: failure.trace
            ),
            identifierPrefix: "localEngineFailure",
            pinsAction: true,
            perform: { engine.install() }
        )
        .padding(.horizontal, 32)
        .padding(.top, PalMetrics.macPanelTitleClearance)
        .padding(.bottom, 28)
        .frame(maxWidth: 484, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        PanelColumn {
            VStack(spacing: 0) {
                PanelHero(symbol: "checkmark", ink: .success)
                Text("Pal is running on this Mac")
                    .hermesText(.sheetTitle)
                    .foregroundStyle(PalTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("localEngineDoneTitle")
                    .padding(.top, 14)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing you in")
                }
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textSecondary)
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("localEngineSigningIn")
            }
        } action: {
            EmptyView()
        }
    }
}

private struct PanelColumn<Main: View, Action: View>: View {
    @ViewBuilder let main: Main
    @ViewBuilder let action: Action

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            main
            Spacer(minLength: 0)
            action
        }
        .padding(.horizontal, 32)
        .padding(.top, PalMetrics.macPanelTitleClearance)
        .padding(.bottom, 28)
        .frame(maxWidth: 484, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}

private struct PanelHero: View {
    let symbol: String
    let ink: PalIconInk

    var body: some View {
        PalIcon(symbol, ink: ink)
            .font(.system(size: 26, weight: .regular))
            .frame(width: 64, height: 64)
            .background(PalTokens.control, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct FactRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            PalIcon(symbol, ink: .secondary)
                .font(.system(size: 14))
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(PalTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }
}

private struct StepRow: View {
    let step: InstallStep
    let status: InstallStepStatus

    var body: some View {
        HStack(spacing: 12) {
            indicator
                .frame(width: 22, height: 22)
            Text(step.title)
                .font(.system(size: 13))
                .foregroundStyle(status == .pending ? PalTokens.textTertiary : PalTokens.textPrimary)
            Spacer(minLength: 0)
            if status == .current {
                Text("Working")
                    .font(.system(size: 12))
                    .foregroundStyle(PalTokens.textSecondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(valueText))
        .accessibilityIdentifier("localEngineStep-\(step.rawValue)")
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .done: PalIcon("checkmark.circle.fill", ink: .success).font(.system(size: 17))
        case .current: ProgressView().controlSize(.small)
        case .pending: PalIcon("circle", ink: .tertiary).font(.system(size: 17))
        }
    }

    private var valueText: String {
        switch status {
        case .done: String(localized: "Done")
        case .current: String(localized: "Working")
        case .pending: String(localized: "Waiting")
        }
    }
}

private struct PanelButton: View {
    enum Kind {
        case primary
        case secondary
    }

    let title: String
    let kind: Kind
    let identifier: String
    let action: () -> Void

    var body: some View {
        switch kind {
        case .primary:
            Button(action: action) { label }
                .glassButtonStyle(prominent: true, tint: PalTokens.inverseFill)
                .buttonBorderShape(.capsule)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(identifier)
        case .secondary:
            Button(action: action) { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(identifier)
        }
    }

    private var label: some View {
        Text(title)
            .foregroundStyle(kind == .primary ? PalTokens.inverseText : PalTokens.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 40)
    }
}
#endif
