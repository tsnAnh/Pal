import PalProtocol

extension ChatInstallModel {
    public func reopen(_ step: ChatProviderCapability) async -> Bool {
        guard let scope, let state, Self.guidedSteps.contains(step),
              state.step == .needsManualStep || state.step == .needsAllow || state.step == .error else { return false }
        var accepted = false
        await mutate {
            try await self.client.advance(
                scope, ChatInstallAdvance(event: .reopenStep, expectedRevision: state.revision, manualStep: step)
            )
            accepted = true
        }
        return accepted
    }
}
