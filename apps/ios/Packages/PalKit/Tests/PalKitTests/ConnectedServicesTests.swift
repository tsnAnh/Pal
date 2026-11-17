import Foundation
import PalConnect
import Synchronization
import Testing

private struct Item: ServiceSuggestion, Equatable {
    let name: String
    let requiredService: ServiceKind?
}

private func catalog(slackState: ConnectAppState?) -> ConnectCatalog {
    let status: PalCatalogEntry.Status = switch slackState {
    case .connected?: .connected
    case .needsAuthorization?: .needsReconnect
    default: .notConnected
    }
    let slack = PalCatalogEntry(slug: "slack", name: "Slack", category: "Communication", method: .mcpOAuth, status: status)
    return ConnectCatalog.make(catalog: [slack], mcp: [])
}

@Suite("Connected services")
struct ConnectedServicesTests {
    private let slackItem = Item(name: "Add to Slack", requiredService: .slack)
    private let freeItem = Item(name: "Routines", requiredService: nil)

    @Test func slackSuggestionIsHiddenUntilTheCatalogIsKnown() {
        #expect(ConnectedServices.unknown.visible([slackItem]).isEmpty)
        #expect(!ConnectedServices.unknown.isKnown)
    }

    @Test func slackSuggestionIsHiddenWhenSlackIsNotConnected() {
        let services = ConnectedServices(catalog: catalog(slackState: nil))
        #expect(services.isKnown)
        #expect(services.visible([slackItem]).isEmpty)
    }

    @Test func slackSuggestionIsHiddenWhenSlackNeedsAuthorization() {
        let services = ConnectedServices(catalog: catalog(slackState: .needsAuthorization))
        #expect(services.visible([slackItem]).isEmpty)
    }

    @Test func slackSuggestionShowsWhenSlackIsConnected() {
        let services = ConnectedServices(catalog: catalog(slackState: .connected))
        #expect(services.visible([slackItem]) == [slackItem])
    }

    @Test(arguments: [(PalCatalogEntry.Status.connected, true), (.needsReconnect, false), (.notConnected, false)])
    func upworkIsConnectedExactlyWhenItsCatalogRowIs(status: PalCatalogEntry.Status, connected: Bool) {
        let row = PalCatalogEntry(slug: "upwork", name: "Upwork", category: "Sales and support", method: .mcpOAuth, status: status)
        let services = ConnectedServices(catalog: ConnectCatalog.make(catalog: [row], mcp: []))
        #expect(services.isConnected(.upwork) == connected)
    }

    @MainActor
    @Test func autoApproveAddressesTheServerByItsCatalogName() async {
        let seen = Mutex<String?>(nil)
        let approve = ActionAutoApprove { _, params in
            seen.withLock { $0 = params?["server"]?.stringValue }
            return ["enabled": false, "eligible": true]
        }
        await approve.load(sessionID: "s1")
        #expect(seen.withLock { $0 } == "upwork")
        #expect(ActionAutoApprove.server == ServiceKind.upwork.connectorSlug)
    }

    @Test func suggestionsWithoutAServiceAlwaysShow() {
        #expect(ConnectedServices.unknown.visible([freeItem, slackItem]) == [freeItem])
    }

    @Test func everyServiceKindMapsToAConnectorSlug() {
        for kind in ServiceKind.allCases { #expect(!kind.connectorSlug.isEmpty) }
    }
}
