import PalDesign
import SwiftUI

extension ConnectionView {
    var showsLocalEngineSetup: Bool {
        #if os(macOS)
        switch model.localEngine.state {
        case .detecting, .removing, .ready: false
        default: true
        }
        #else
        false
        #endif
    }

    @ViewBuilder
    var localEngineSetupButton: some View {
        #if os(macOS)
        if showsLocalEngineSetup {
            Button {
                model.localEngine.presentSetup()
            } label: {
                capsuleLabel(String(localized: "Set up Pal on this Mac"), leading: PalIcon("laptopcomputer", ink: .onInverseFill))
            }
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            .disabled(model.isBusy)
            .accessibilityIdentifier("localEngineSetupButton")
        }
        #endif
    }

    @ViewBuilder
    var localEngineHelper: some View {
        #if os(macOS)
        if showsLocalEngineSetup {
            Text("No server? Run Pal on this Mac.")
                .font(.system(size: SignInMetrics.footnoteSize + 1))
                .foregroundStyle(tone.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, SignInMetrics.cardToMessage)
        }
        #endif
    }

    @ViewBuilder
    var localEngineRunningCard: some View {
        #if os(macOS)
        if case .ready = model.localEngine.state {
            LocalEngineRunningCard(engine: model.localEngine, tone: tone, isBusy: model.isBusy)
                .padding(.bottom, SignInMetrics.messageToButton)
        }
        #endif
    }
}

#if os(macOS)
private struct LocalEngineRunningCard: View {
    let engine: LocalEngineModel
    let tone: SignInTone
    let isBusy: Bool

    @Environment(\.hermesTheme) private var theme

    var body: some View {
        HStack(spacing: SignInMetrics.rowSpacing) {
            Circle()
                .fill(Color(theme.palette.workingDot))
                .frame(width: 8, height: 8)
                .frame(width: SignInMetrics.rowGlyphWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pal is running on this Mac")
                    .font(.system(size: SignInMetrics.rowTextSize, weight: .semibold))
                    .foregroundStyle(tone.primaryText)
                Text("Ready to sign in")
                    .font(.system(size: SignInMetrics.checkingSize))
                    .foregroundStyle(tone.secondaryText)
            }
            Spacer(minLength: 8)
            Button {
                Task { await engine.continueWithRunningEngine() }
            } label: {
                Text("Continue")
                    .font(.system(size: SignInMetrics.checkingSize + 1))
                    .foregroundStyle(tone.primaryText)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 22)
            }
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            .disabled(isBusy || engine.isSigningIn)
            .accessibilityIdentifier("localEngineContinue")
        }
        .padding(.horizontal, SignInMetrics.rowInset)
        .frame(minHeight: SignInMetrics.rowHeight)
        .background(tone.buttonFill, in: RoundedRectangle(cornerRadius: SignInMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: SignInMetrics.cardRadius).strokeBorder(tone.buttonRim, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localEngineRunningCard")
    }
}
#endif

extension View {
    @ViewBuilder
    func localEngineSetup(_ model: ConnectionModel) -> some View {
        #if os(macOS)
        self
            .overlay { LocalEngineSetupHost(engine: model.localEngine) }
            .task { await model.localEngine.detect() }
        #else
        self
        #endif
    }
}
