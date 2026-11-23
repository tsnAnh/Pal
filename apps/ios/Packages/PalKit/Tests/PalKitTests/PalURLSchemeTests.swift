import Foundation
import PalProtocol
import Testing

@Suite("Pal URL scheme")
struct PalURLSchemeTests {
    @Test func theTestHostRegistersNoSchemeSoTheReleaseSchemeApplies() {
        #expect(PalURLScheme.current == .release)
        #expect(PalURLScheme(bundle: .main) == .release)
    }

    @Test func buildsAreToldApartByAnExactRawValue() {
        #expect(PalURLScheme(rawValue: "dev.tsnanh.hermes.bot") == .release)
        #expect(PalURLScheme(rawValue: "dev.tsnanh.hermes.bot.dev") == .development)
        #expect(PalURLScheme(rawValue: "DEV.tsnanh.hermes.bot.dev") == nil)
        #expect(PalURLScheme(rawValue: "javascript:alert(1)") == nil)
    }

    @Test func onlyADevelopmentBuildPutsItsSchemeOnTheWire() {
        #expect(PalURLScheme.release.wireParameters.isEmpty)
        #expect(PalURLScheme.development.wireParameters == ["app_scheme": "dev.tsnanh.hermes.bot.dev"])
    }

    @Test func theMcpRedirectCarriesTheBuildsScheme() {
        #expect(PalURLScheme.release.mcpRedirectURI == "dev.tsnanh.hermes.bot:/mcp-oauth/callback")
        #expect(PalURLScheme.development.mcpRedirectURI == "dev.tsnanh.hermes.bot.dev:/mcp-oauth/callback")
    }
}
