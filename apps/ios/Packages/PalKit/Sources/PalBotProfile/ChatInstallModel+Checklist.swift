import Foundation
import PalProtocol

extension ChatInstallModel {
    public var checklist: [ChatSetupChecklistItem] {
        guard let provider, let state else { return [] }
        let guided = Self.guidedSteps.filter { step in provider.capabilities.contains { $0.capability == step && $0.mode == .guided } }
        var kinds: [ChatSetupChecklistItem.Kind] = []
        if provider.requiresConfigCredential { kinds.append(.workspace) }
        if provider.createsApp { kinds.append(.createApp) }
        kinds += guided.map { .manual($0) }
        kinds += [.allow, .install]
        let current = activeKind(state)
        let currentIndex = current.flatMap(kinds.firstIndex(of:)) ?? (state.step == .ready ? kinds.count : 0)
        return kinds.enumerated().map { index, kind in
            let status: ChatSetupChecklistItem.Status
            if case .manual(let step) = kind, state.manualStepsDone.contains(step) {
                status = .done
            } else if index < currentIndex {
                status = .done
            } else {
                status = index == currentIndex ? .active : .pending
            }
            return ChatSetupChecklistItem(kind: kind, status: status)
        }
    }

    private func activeKind(_ state: ChatSetupStateWire) -> ChatSetupChecklistItem.Kind? {
        switch state.step {
        case .needsCredential: .workspace
        case .creatingApp: .createApp
        case .needsManualStep:
            ChatProviderCapability(rawValue: state.nextAction.actionId).map { .manual($0) }
        case .needsAllow, .needsOwner: .allow
        case .installing: .install
        default: nil
        }
    }

    var pendingTask: ChatProviderCapability? {
        guard let state else { return nil }
        if let id = ChatProviderCapability(rawValue: state.nextAction.actionId), Self.guidedSteps.contains(id) { return id }
        return checklist.lazy.compactMap { item -> ChatProviderCapability? in
            if case .manual(let step) = item.kind, item.status != .done { return step }
            return nil
        }.first
    }
}
