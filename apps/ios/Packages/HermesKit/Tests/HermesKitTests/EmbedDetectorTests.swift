import Foundation
import HermesChat
import Testing

@Suite("Embed detector")
struct EmbedDetectorTests {
    private func detect(_ string: String) -> EmbedDescriptor? {
        URL(string: string).flatMap(EmbedDetector.detect)
    }

    private func embed(_ string: String) -> String? {
        detect(string)?.embedURL.absoluteString
    }

    @Test func youtubeWatchLink() throws {
        let descriptor = try #require(detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(descriptor.provider == .youtube)
        #expect(descriptor.id == "youtube:dQw4w9WgXcQ")
        #expect(descriptor.label == "YouTube")
        #expect(descriptor.embedURL.absoluteString == "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0")
        #expect(descriptor.sourceURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(descriptor.aspectRatio == 16.0 / 9.0)
        #expect(descriptor.maxWidth == 640)
        #expect(descriptor.height == nil)
    }

    @Test func youtubeHostAndPathVariants() {
        let id = "dQw4w9WgXcQ"
        let expected = "https://www.youtube-nocookie.com/embed/\(id)?modestbranding=1&rel=0"
        for link in [
            "https://youtu.be/\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://mobile.youtube.com/watch?v=\(id)",
            "https://youtube.com/embed/\(id)",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/live/\(id)",
            "https://www.youtube.com/v/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "http://www.youtube.com/watch?v=\(id)",
        ] {
            #expect(embed(link) == expected, "\(link)")
        }
    }

    @Test func youtubeStartTime() {
        let base = "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?modestbranding=1&rel=0"
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=90") == base + "&start=90")
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=1m30s") == base + "&start=90")
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=1h2m3s") == base + "&start=3723")
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?start=15") == base + "&start=15")
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=&start=15") == base + "&start=15")
        #expect(embed("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=45s") == base + "&start=45")
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=0") == base)
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=abc") == base)
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=1s2m") == base)
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=99999999999") == base)
        #expect(embed("https://youtu.be/dQw4w9WgXcQ?t=5x") == base)
    }

    @Test func youtubeRejections() {
        for link in [
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/watch?v=dQw4w9WgXc!",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQQ",
            "https://www.youtube.com/channel/dQw4w9WgXcQ",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/",
        ] {
            #expect(detect(link) == nil, "\(link)")
        }
    }

    @Test func lookAlikeHostsAreRejected() {
        for link in [
            "https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ",
            "https://evilyoutube.com/watch?v=dQw4w9WgXcQ",
            "https://notyoutu.be/dQw4w9WgXcQ",
            "https://vimeo.com.evil.test/76979871",
            "https://evil-vimeo.com/76979871",
            "https://open.spotify.com.evil.test/track/4uLU6hMCjMI75M1A2tKUQC",
            "https://nottwitter.com/a/status/1",
            "https://x.com.evil.test/a/status/1",
            "https://instagram.com.evil.test/p/abc/",
            "https://tiktok.com.evil.test/@u/video/1",
            "https://openstreetmap.org.evil.test/#map=15/21.0/105.0",
            "https://google.evil.test/maps?q=a",
            "https://evil-pinterest.com.attacker.test/pin/1/",
            "https://pinterest.evil.test/pin/1/",
        ] {
            #expect(detect(link) == nil, "\(link)")
        }
    }

    @Test func userinfoAndPortsAreRejected() {
        #expect(detect("https://user:pw@www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("https://user@www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("https://youtube.com@evil.test/watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("https://www.youtube.com:8443/watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("http://www.youtube.com:443/watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("https://www.youtube.com:443/watch?v=dQw4w9WgXcQ") != nil)
    }

    @Test func onlyHTTPSourcesAreAccepted() {
        #expect(detect("ftp://www.youtube.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("file:///watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("javascript:alert(1)") == nil)
        #expect(detect("youtube://watch?v=dQw4w9WgXcQ") == nil)
        #expect(detect("mailto:a@example.com") == nil)
    }

    @Test func embedURLsAreAlwaysHTTPSOnAllowedHosts() {
        let sources = [
            "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "http://vimeo.com/76979871",
            "http://www.instagram.com/p/CxYz_-12/",
            "http://www.pinterest.com/pin/123/",
            "http://www.tiktok.com/@u/video/123",
            "http://twitter.com/jack/status/20",
            "http://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
            "http://www.google.com/maps/@21.0285,105.8542,15z",
            "http://www.openstreetmap.org/#map=15/21.0285/105.8542",
        ]
        for source in sources {
            guard let descriptor = detect(source) else {
                Issue.record("no descriptor for \(source)")
                continue
            }
            #expect(descriptor.embedURL.scheme == "https")
            #expect(descriptor.embedURL.host().map(EmbedDetector.allowedEmbedHosts.contains) == true, "\(source)")
            #expect(descriptor.sourceURL.absoluteString == source)
        }
        #expect(EmbedDetector.allowedEmbedHosts.allSatisfy { !$0.contains("/") && $0 == $0.lowercased() })
    }

    @Test func vimeo() {
        #expect(embed("https://vimeo.com/76979871") == "https://player.vimeo.com/video/76979871")
        #expect(embed("https://vimeo.com/channels/staffpicks/76979871") == "https://player.vimeo.com/video/76979871")
        #expect(embed("https://vimeo.com/groups/x/videos/76979871") == "https://player.vimeo.com/video/76979871")
        #expect(embed("https://player.vimeo.com/video/76979871") == "https://player.vimeo.com/video/76979871")
        #expect(detect("https://vimeo.com/about") == nil)
        #expect(detect("https://vimeo.com/") == nil)
        #expect(detect("https://vimeo.com/76979871")?.id == "vimeo:76979871")
        #expect(detect("https://vimeo.com/76979871")?.aspectRatio == 16.0 / 9.0)
    }

    @Test func instagram() {
        #expect(embed("https://www.instagram.com/p/CxYz_-12/") == "https://www.instagram.com/p/CxYz_-12/embed")
        #expect(embed("https://instagram.com/reel/ABC123/") == "https://www.instagram.com/reel/ABC123/embed")
        #expect(embed("https://www.instagram.com/reels/ABC123/") == "https://www.instagram.com/reel/ABC123/embed")
        #expect(embed("https://www.instagram.com/tv/ABC123/") == "https://www.instagram.com/tv/ABC123/embed")
        #expect(detect("https://www.instagram.com/p/CxYz_-12/")?.height == 450)
        #expect(detect("https://www.instagram.com/p/CxYz_-12/")?.maxWidth == 400)
        #expect(detect("https://www.instagram.com/someuser/") == nil)
        #expect(detect("https://www.instagram.com/p/") == nil)
        #expect(detect("https://www.instagram.com/p/a%24b/") == nil)
        #expect(detect("https://www.instagram.com/stories/abc/") == nil)
    }

    @Test func pinterest() {
        let expected = "https://assets.pinterest.com/ext/embed.html?id=123456789"
        #expect(embed("https://www.pinterest.com/pin/123456789/") == expected)
        #expect(embed("https://fr.pinterest.com/pin/123456789/") == expected)
        #expect(embed("https://pinterest.co.uk/pin/123456789/") == expected)
        #expect(embed("https://www.pinterest.com.au/pin/123456789/") == expected)
        #expect(embed("https://pinterest.de/pin/123456789/") == expected)
        #expect(detect("https://www.pinterest.com/pin/abc/") == nil)
        #expect(detect("https://www.pinterest.com/someone/board/") == nil)
        #expect(detect("https://www.pinterest.com/pin/123456789/")?.height == 380)
    }

    @Test func tiktok() {
        #expect(embed("https://www.tiktok.com/@user/video/7234567890123456789") == "https://www.tiktok.com/player/v1/7234567890123456789")
        #expect(embed("https://m.tiktok.com/@user/video/123") == "https://www.tiktok.com/player/v1/123")
        #expect(detect("https://www.tiktok.com/@user/video/7234567890123456789")?.aspectRatio == 9.0 / 16.0)
        #expect(detect("https://www.tiktok.com/@user") == nil)
        #expect(detect("https://www.tiktok.com/@user/video/abc") == nil)
        #expect(detect("https://vm.tiktok.com/ZMabc/") == nil)
    }

    @Test func twitter() throws {
        let descriptor = try #require(detect("https://twitter.com/jack/status/20"))
        #expect(descriptor.provider == .twitter)
        #expect(descriptor.label == "X")
        #expect(descriptor.id == "twitter:20")
        #expect(descriptor.embedURL.absoluteString == "https://platform.twitter.com/embed/Tweet.html?id=20&theme=light&dnt=true")
        #expect(descriptor.embedURL(dark: true).absoluteString == "https://platform.twitter.com/embed/Tweet.html?id=20&theme=dark&dnt=true")
        #expect(descriptor.embedURL(dark: false) == descriptor.embedURL)
        #expect(detect("https://x.com/jack/status/20/photo/1")?.id == "twitter:20")
        #expect(detect("https://mobile.twitter.com/jack/status/20")?.id == "twitter:20")
        #expect(detect("https://x.com/jack") == nil)
        #expect(detect("https://x.com/jack/status/abc") == nil)
        #expect(detect("https://x.com/jack/status/") == nil)
    }

    @Test func nonTwitterDescriptorsIgnoreTheme() throws {
        let descriptor = try #require(detect("https://vimeo.com/76979871"))
        #expect(descriptor.embedURL(dark: true) == descriptor.embedURL)
    }

    @Test func spotify() {
        let track = "4uLU6hMCjMI75M1A2tKUQC"
        #expect(embed("https://open.spotify.com/track/\(track)") == "https://open.spotify.com/embed/track/\(track)")
        #expect(embed("https://open.spotify.com/intl-de/album/\(track)?si=abc") == "https://open.spotify.com/embed/album/\(track)")
        #expect(embed("https://open.spotify.com/playlist/\(track)") == "https://open.spotify.com/embed/playlist/\(track)")
        #expect(detect("https://open.spotify.com/track/\(track)")?.height == 152)
        #expect(detect("https://open.spotify.com/track/\(track)")?.id == "spotify:track:\(track)")
        #expect(detect("https://open.spotify.com/user/foo") == nil)
        #expect(detect("https://open.spotify.com/track/") == nil)
        #expect(detect("https://open.spotify.com/track/a-b") == nil)
        #expect(detect("https://spotify.com/track/\(track)") == nil)
    }

    @Test func googleMapsCoordinates() {
        let descriptor = detect("https://www.google.com/maps/@21.0285,105.8542,15z")
        #expect(descriptor?.provider == .googlemaps)
        #expect(descriptor?.embedURL.absoluteString == "https://maps.google.com/maps?output=embed&q=21.0285%2C105.8542&z=15")
        #expect(descriptor?.id == "googlemaps:21.0285,105.8542@15")
        #expect(descriptor?.aspectRatio == 16.0 / 10.0)
        #expect(embed("https://www.google.com/maps/@-33.8,151.2,15.5z")?.hasSuffix("q=-33.8%2C151.2&z=16") == true)
        #expect(embed("https://www.google.com/maps/@21.0285,105.8542")?.hasSuffix("q=21.0285%2C105.8542") == true)
    }

    @Test func googleMapsQueryAndPlace() {
        #expect(embed("https://www.google.com/maps?q=Eiffel+Tower") == "https://maps.google.com/maps?output=embed&q=Eiffel+Tower")
        #expect(embed("https://www.google.com/maps?query=Eiffel%20Tower") == "https://maps.google.com/maps?output=embed&q=Eiffel+Tower")
        #expect(embed("https://maps.google.com/?q=Paris") == "https://maps.google.com/maps?output=embed&q=Paris")
        #expect(embed("https://www.google.com/maps/place/Hanoi+Opera+House") == "https://maps.google.com/maps?output=embed&q=Hanoi+Opera+House")
        #expect(embed("https://www.google.com/maps/place/Hanoi+Opera+House/@21.02,105.85,17z") == "https://maps.google.com/maps?output=embed&q=21.02%2C105.85&z=17")
        #expect(embed("https://www.google.co.uk/maps?q=a") == "https://maps.google.com/maps?output=embed&q=a")
        #expect(embed("https://www.google.com/maps?q=caf%C3%A9") == "https://maps.google.com/maps?output=embed&q=caf%C3%A9")
    }

    @Test func googleMapsRejections() {
        #expect(detect("https://www.google.com/search?q=x") == nil)
        #expect(detect("https://www.google.com/maps") == nil)
        #expect(detect("https://www.google.com/maps?q=") == nil)
        #expect(detect("https://www.google.xyz/maps?q=a") == nil)
        #expect(detect("https://mail.google.com/maps?q=a") == nil)
    }

    @Test func openStreetMap() {
        let descriptor = detect("https://www.openstreetmap.org/#map=15/21.0285/105.8542")
        #expect(descriptor?.provider == .openstreetmap)
        #expect(descriptor?.id == "openstreetmap:21.0285,105.8542@15")
        #expect(
            descriptor?.embedURL.absoluteString
                == "https://www.openstreetmap.org/export/embed.html?bbox=105.84871%2C21.02575%2C105.85969%2C21.03125&layer=mapnik&marker=21.0285%2C105.8542"
        )
        #expect(detect("https://www.openstreetmap.org/") == nil)
        #expect(detect("https://www.openstreetmap.org/#map=15/91/105") == nil)
        #expect(detect("https://www.openstreetmap.org/#map=15/21.0") == nil)
        #expect(detect("https://www.openstreetmap.org/#map=99/21.0/105.0") == nil)
    }

    @Test func plainLinksAreNotEmbeds() {
        for link in ["https://example.com", "https://github.com/a/b", "https://www.google.com/", "not a url", "https://"] {
            #expect(detect(link) == nil, "\(link)")
        }
    }

    @Test func oversizedURLsAreRejected() {
        let long = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&x=" + String(repeating: "a", count: 5_000)
        #expect(detect(long) == nil)
    }

    @Test func providerListIsStable() {
        #expect(Set(EmbedProvider.allCases.map(\.rawValue)) == [
            "youtube", "vimeo", "instagram", "pinterest", "tiktok", "twitter", "spotify", "googlemaps", "openstreetmap",
        ])
    }

    @Test func descriptorsAreHashableByValue() throws {
        let one = try #require(detect("https://youtu.be/dQw4w9WgXcQ"))
        let two = try #require(detect("https://youtu.be/dQw4w9WgXcQ"))
        #expect(one == two)
        #expect(Set([one, two]).count == 1)
        #expect(one.id == "youtube:dQw4w9WgXcQ")
    }

    @Test func startSecondsParser() {
        #expect(EmbedDetector.startSeconds("90") == 90)
        #expect(EmbedDetector.startSeconds("1h") == 3600)
        #expect(EmbedDetector.startSeconds("2m") == 120)
        #expect(EmbedDetector.startSeconds("1h1m1s") == 3661)
        #expect(EmbedDetector.startSeconds("0s") == nil)
        #expect(EmbedDetector.startSeconds("m") == nil)
        #expect(EmbedDetector.startSeconds("1m1h") == nil)
        #expect(EmbedDetector.startSeconds("1") == 1)
        #expect(EmbedDetector.startSeconds("") == nil)
    }
}
