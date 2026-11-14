#if os(macOS)
import AppKit
import Foundation
import PalDevice
import PalDiagnostics
import PalT3Code
import Synchronization

@MainActor
final class T3CodeHost {
    static let baseDirectoryArgument = "hermes-test-t3-base-dir"

    let bridge: T3McpBridge
    let controller: T3CodeController
    private let hosts: HostSource

    init() {
        let override = UserDefaults.standard.string(forKey: Self.baseDirectoryArgument).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let locator = T3Locator.standard(baseDirectory: override)
        let tokens = KeychainT3TokenStore()
        let bridge = T3McpBridge(locator: locator, tokens: tokens, diagnostics: .osLog())
        let hosts = HostSource()
        let controller = T3CodeController(
            locator: locator,
            tokens: tokens,
            authorizer: T3OAuthAuthorizer(browser: SystemBrowserAuthorization(), diagnostics: .osLog()),
            registrar: T3HostRegistrar { await hosts.current() },
            bridge: bridge,
            diagnostics: .osLog()
        )
        self.bridge = bridge
        self.controller = controller
        self.hosts = hosts
        Task { [weak controller] in await bridge.observeUnauthorized { [weak controller] in await controller?.unauthorized() } }
    }

    func bind(hosts source: @escaping @MainActor () -> [DeviceToolHost]) {
        hosts.bind(source)
    }

    func openApplication() {
        guard let url = controller.installedApplicationURL() else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private final class HostSource: Sendable {
        private let source = Mutex<(@MainActor () -> [DeviceToolHost])?>(nil)

        func bind(_ value: @escaping @MainActor () -> [DeviceToolHost]) {
            source.withLock { $0 = value }
        }

        func current() async -> [DeviceToolHost] {
            guard let provide = source.withLock({ $0 }) else { return [] }
            return await MainActor.run { provide() }
        }
    }
}
#endif
