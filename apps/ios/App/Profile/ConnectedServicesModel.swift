import Foundation
import PalConnect
import Observation

@MainActor
@Observable
final class ConnectedServicesModel {
    private(set) var services = ConnectedServices.unknown

    private let botName: String
    private let loadCatalog: @Sendable (String) async throws -> ConnectCatalog

    init(botName: String, services: BotsServices) {
        self.botName = botName
        loadCatalog = services.connectCatalog
    }

    static let assumedConnectedArgument = "-hermes-test-connected-services"

    func load() async {
        if let assumed = Self.assumedConnected() {
            services = ConnectedServices(connected: assumed)
            return
        }
        guard let catalog = try? await loadCatalog(botName) else { return }
        services = ConnectedServices(catalog: catalog)
    }

    private static func assumedConnected() -> Set<ServiceKind>? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: assumedConnectedArgument), index + 1 < arguments.count else { return nil }
        return Set(arguments[index + 1].split(separator: ",").compactMap { ServiceKind(rawValue: String($0)) })
    }
}
