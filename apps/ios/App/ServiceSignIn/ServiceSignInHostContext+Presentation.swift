import SwiftUI

extension ServiceSignInHostContext {
    func presentation(for host: UUID) -> Binding<Bool> {
        Binding(
            get: { center.current != nil && hosts.presents(host) },
            set: { if !$0 { Task { await center.notNow() } } }
        )
    }
}
