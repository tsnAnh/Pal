import Foundation
import PalConnect

struct AddressFlowItem: Identifiable {
    let id = UUID()
    let model: StepFlowModel
}

extension ConnectAppsModel {
    func openT3Code() {
        let resume: T3CodeFlow.Resume? = switch t3Reach {
        case .unreachable: .address
        case .needsSignIn: .signIn
        case .reachable, nil: nil
        }
        guard let engine = T3CodeFlow.engine(resumeAt: resume) else { return }
        let model = StepFlowModel(
            engine: engine, runner: T3CodeFlow.runner(service: service), classify: { T3CodeFlow.classify($0) }
        )
        t3Flow = AddressFlowItem(model: model)
    }

    func probeT3Code() async {
        guard catalog.apps.contains(where: { $0.isT3Code && $0.state == .connected }) else {
            t3Reach = nil
            return
        }
        t3Reach = await service.probeT3Code()
    }
}
