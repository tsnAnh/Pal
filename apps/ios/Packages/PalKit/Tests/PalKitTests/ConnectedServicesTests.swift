import Foundation
import PalConnect
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

    @Test func suggestionsWithoutAServiceAlwaysShow() {
        #expect(ConnectedServices.unknown.visible([freeItem, slackItem]) == [freeItem])
    }

    @Test func everyServiceKindMapsToAConnectorSlug() {
        for kind in ServiceKind.allCases { #expect(!kind.connectorSlug.isEmpty) }
    }
}
