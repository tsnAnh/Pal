import Foundation
import PalConnect

extension OwnerSetupModel {
    var currentStepID: String? { currentStep?.id }

    func checksAddress(on step: FlowStep) -> Bool {
        guard context?.usesClient == true, case .copyCard(let copies) = step.kind else { return false }
        return copies.contains { $0.value.hasPrefix("https://") }
    }

    func checkAddressIfNeeded() async {
        guard let step = currentStep, checksAddress(on: step) else { return }
        await checkAddress()
    }

    func checkAddress() async {
        guard addressCheck != .checking else { return }
        addressCheck = .checking
        do {
            let check = try await service.checkPublicAddress()
            addressCheck = SetupStatus.addressCheck(check).map(AddressCheck.failed) ?? .reachable
        } catch is CancellationError {
            addressCheck = .idle
        } catch {
            addressCheck = .failed(status(for: error))
        }
    }

    func setConfigured(_ value: Bool) {
        configured = value
        context?.configured = value
    }

    func replaceClient() {
        guard let context, let pasteID = Self.pasteStepID(context) else { return }
        setConfigured(false)
        restart(at: pasteID)
    }

    func removeClient() async {
        guard let context, !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await service.removeOAuthClient(slug: context.slug)
        } catch is CancellationError {
            return
        } catch {
            removalFailure = status(for: error)
            return
        }
        setConfigured(false)
        restart(at: OwnerSetupFlow.steps(context)?.dropFirst().first?.id)
    }

    func retryRemoval() async {
        let failed = removalFailure
        removalFailure = nil
        guard failed?.kind != .forbidden else { return }
        await removeClient()
    }
}
