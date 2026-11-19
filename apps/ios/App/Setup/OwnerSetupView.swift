import PalConnect
import PalDesign
import SwiftUI

struct OwnerSetupView: View {
    @Bindable var model: OwnerSetupModel

    var body: some View {
        content
            .background(PalTokens.content)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ownerSetup")
            .task { await model.start() }
            .task(id: model.currentStepID) { await model.checkAddressIfNeeded() }
            .onDisappear { model.discard() }
            .alert(String(localized: "Replace the saved client?"), isPresented: $model.confirmsReplace) {
                Button(String(localized: "Replace"), role: .destructive) { model.replaceClient() }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("The new client replaces the one saved on your Pal.")
            }
            .alert(String(localized: "Remove the saved client?"), isPresented: $model.confirmsRemove) {
                Button(String(localized: "Remove client"), role: .destructive) { Task { await model.removeClient() } }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("Pal forgets this client and signs out of \(model.app.name). You can set up a new client any time.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.removalFailure {
            framed {
                StatusBlock(status: failure, identifierPrefix: "ownerSetupRemoval") { Task { await model.retryRemoval() } }
                    .frame(maxHeight: .infinity)
            }
        } else {
            switch model.phase {
            case .loading:
                framed {
                    DelayedProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("ownerSetupBusy")
                }
            case .failed(let status):
                framed {
                    StatusBlock(status: status, identifierPrefix: "ownerSetupStatus") { Task { await model.retry() } }
                        .frame(maxHeight: .infinity)
                }
            case .ready(let flow):
                StepFlowView(
                    model: flow, title: model.app.name, savedNote: String(localized: "Saved on your Pal. Mac and iPhone show the same step."),
                    close: { finish() }, accessory: { step in OwnerSetupAccessory(model: model, step: step) }
                )
            }
        }
    }

    private func finish() {
        Task { await model.finish() }
    }

    private func framed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            SetupHeader(title: model.app.name, close: { finish() })
            content()
        }
    }
}

private struct OwnerSetupAccessory: View {
    let model: OwnerSetupModel
    let step: FlowStep

    var body: some View {
        if model.checksAddress(on: step) { addressStatus }
        if step.id == OwnerSetupFlow.StepID.signIn, model.configured { clientActions }
    }

    @ViewBuilder
    private var addressStatus: some View {
        switch model.addressCheck {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: PalMetrics.captionToCardGap) {
                ProgressView().controlSize(.small)
                Text("Checking that Pal can be reached at this address.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ownerSetupAddressChecking")
        case .reachable:
            Label {
                Text("Pal reached this address from outside.")
                    .hermesText(.rowSubtitle)
                    .foregroundStyle(PalTokens.textSecondary)
            } icon: {
                PalIcon("checkmark.circle.fill", ink: .success)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ownerSetupAddressReachable")
        case .failed(let status):
            StatusBlock(status: status, identifierPrefix: "ownerSetupAddress") { Task { await model.checkAddress() } }
        }
    }

    private var clientActions: some View {
        VStack(alignment: .leading, spacing: PalMetrics.captionToCardGap) {
            SetupButton(title: String(localized: "Replace saved client"), isBusy: model.isRemoving, identifier: "ownerSetupReplace") {
                model.confirmsReplace = true
            }
            SetupButton(title: String(localized: "Remove saved client"), isBusy: model.isRemoving, identifier: "ownerSetupRemove") {
                model.confirmsRemove = true
            }
        }
    }
}
