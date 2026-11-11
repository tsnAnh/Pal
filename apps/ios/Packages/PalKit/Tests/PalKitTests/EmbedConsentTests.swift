import Foundation
import PalChat
import Testing

@Suite("Embed consent")
struct EmbedConsentTests {
    private func descriptor(_ link: String) throws -> EmbedDescriptor {
        try #require(URL(string: link).flatMap(EmbedDetector.detect))
    }

    @Test func nothingIsPermittedByDefault() throws {
        let video = try descriptor("https://youtu.be/dQw4w9WgXcQ")
        #expect(!EmbedConsent().permits(video, onceLoaded: []))
    }

    @Test func onceLoadedPermitsOnlyThatEmbed() throws {
        let video = try descriptor("https://youtu.be/dQw4w9WgXcQ")
        let other = try descriptor("https://youtu.be/aaaaaaaaaaa")
        let consent = EmbedConsent()
        #expect(consent.permits(video, onceLoaded: [video.id]))
        #expect(!consent.permits(other, onceLoaded: [video.id]))
    }

    @Test func alwaysAllowedCoversEveryEmbedOfTheProvider() throws {
        let video = try descriptor("https://youtu.be/dQw4w9WgXcQ")
        let other = try descriptor("https://youtu.be/aaaaaaaaaaa")
        let vimeo = try descriptor("https://vimeo.com/76979871")
        var consent = EmbedConsent()
        consent.allowAlways(.youtube)
        #expect(consent.permits(video, onceLoaded: []))
        #expect(consent.permits(other, onceLoaded: []))
        #expect(!consent.permits(vimeo, onceLoaded: []))
    }

    @Test func revokeRemovesTheGrant() throws {
        let video = try descriptor("https://youtu.be/dQw4w9WgXcQ")
        var consent = EmbedConsent(alwaysAllowed: [.youtube, .vimeo])
        consent.revoke(.youtube)
        #expect(!consent.permits(video, onceLoaded: []))
        #expect(consent.alwaysAllowed == [.vimeo])
        consent.revoke(.youtube)
        #expect(consent.alwaysAllowed == [.vimeo])
    }

    @Test func storageRoundTrip() {
        let consent = EmbedConsent(alwaysAllowed: [.twitter, .youtube, .googlemaps])
        #expect(consent.storageValue == ["googlemaps", "twitter", "youtube"])
        #expect(EmbedConsent(storageValue: consent.storageValue) == consent)
    }

    @Test func storageIgnoresUnknownAndDuplicateEntries() {
        let consent = EmbedConsent(storageValue: ["youtube", "youtube", "myspace", "", "VIMEO", "vimeo"])
        #expect(consent.alwaysAllowed == [.youtube, .vimeo])
    }

    @Test func emptyStorage() {
        #expect(EmbedConsent(storageValue: []) == EmbedConsent())
        #expect(EmbedConsent().storageValue.isEmpty)
    }

    @Test func everyProviderSurvivesTheRoundTrip() {
        let consent = EmbedConsent(alwaysAllowed: Set(EmbedProvider.allCases))
        #expect(EmbedConsent(storageValue: consent.storageValue).alwaysAllowed == Set(EmbedProvider.allCases))
    }
}
