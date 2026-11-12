#if os(macOS)
import Observation
import PalDevice
import PalProtocol

@MainActor
@Observable
final class MessagesConnectorModel {
    private(set) var state: DeviceConnectorState?
    private(set) var access: MessagesAccess?
    private(set) var changeFailed = false

    private let profile: String?
    private let hostPool: DeviceHostPool

    init(profile: String?, hostPool: DeviceHostPool) {
        self.profile = profile
        self.hostPool = hostPool
    }

    var row: MessagesConnectorRow { .make(host: .mac, state: state, access: access) }

    func load() async {
        guard let stack = await hostPool.stack(for: profile) else { return }
        _ = try? await stack.ledger.refresh()
        state = await stack.ledger.state(for: .messages)
        await refreshAccess()
    }

    func setOn(_ on: Bool) async {
        guard let stack = await hostPool.stack(for: profile) else {
            changeFailed = true
            return
        }
        do {
            try await stack.ledger.set(.messages, state: on ? .allowed : .off)
            changeFailed = false
        } catch {
            changeFailed = true
        }
        state = await stack.ledger.state(for: .messages)
        await refreshAccess()
    }

    func refreshAccess() async {
        guard state == .allowed else {
            access = nil
            return
        }
        access = await Task.detached { MessagesAccessProbe.current() }.value
    }

    func openFullDiskAccess() {
        if let url = SystemSettings.fullDiskAccessURL { SystemSettings.open(url) }
    }
}
#endif
