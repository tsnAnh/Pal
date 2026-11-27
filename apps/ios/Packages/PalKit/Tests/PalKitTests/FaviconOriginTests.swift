import Foundation
import PalChat
import Testing

@Suite("Favicon origin policy")
struct FaviconOriginTests {
    private func host(_ text: String) -> String? {
        URL(string: text).flatMap(FaviconOrigin.host(of:))
    }

    @Test func plainHttpsHostIsAllowedAndLowercased() {
        #expect(host("https://Pay.Google.com/payments") == "pay.google.com")
        #expect(host("https://example.com:443/x") == "example.com")
    }

    @Test func nonHttpsAndOddPortsAreRefused() {
        #expect(host("http://example.com") == nil)
        #expect(host("https://example.com:8443") == nil)
        #expect(host("ftp://example.com") == nil)
    }

    @Test func localAndPrivateTargetsAreRefused() {
        for text in ["https://localhost/", "https://192.168.1.5/", "https://10.0.0.1/", "https://[::1]/", "https://printer.local/",
                     "https://intranet/", "https://box.internal/", "https://127.0.0.1/"] {
            #expect(host(text) == nil, "\(text)")
        }
    }

    @Test func sameSiteAllowsSubdomainsButNotOtherSites() {
        #expect(FaviconOrigin.isSameSite("static.example.com", as: "www.example.com"))
        #expect(FaviconOrigin.isSameSite("example.com", as: "www.example.com"))
        #expect(!FaviconOrigin.isSameSite("evil.com", as: "www.example.com"))
        #expect(!FaviconOrigin.isSameSite("notexample.com", as: "example.com"))
    }

    private func candidates(_ html: String?) throws -> [String] {
        let root = try #require(URL(string: "https://example.com/"))
        return FaviconOrigin.iconCandidates(inHTML: html, rootURL: root).map(\.absoluteString)
    }

    @Test func iconLinkIsResolvedAgainstTheRootAheadOfTheConventionalFile() throws {
        let html = "<html><head><link rel=\"stylesheet\" href=\"/a.css\"><link rel='shortcut icon' href='/static/fav.png'></head>"
        #expect(try candidates(html) == ["https://example.com/static/fav.png", "https://example.com/favicon.ico"])
    }

    @Test func appleTouchIconFollowsARealIconAndLeadsWhenAlone() throws {
        let both = "<link rel=\"apple-touch-icon\" href=\"/touch.png\"><link rel=\"icon\" href=\"/real.ico\">"
        #expect(try candidates(both) == ["https://example.com/real.ico", "https://example.com/favicon.ico", "https://example.com/touch.png"])
        let onlyTouch = "<link rel=\"apple-touch-icon\" href=\"/touch.png\">"
        #expect(try candidates(onlyTouch) == ["https://example.com/touch.png", "https://example.com/favicon.ico"])
    }

    @Test func declaredSizesOrderTheLinksLargestFirstAndBoundTheRequests() throws {
        let html = [16, 192, 32, 96].map { "<link rel=\"icon\" href=\"/\($0).png\" sizes=\"\($0)x\($0)\">" }.joined()
        #expect(try candidates(html) == [192, 96, 32].map { "https://example.com/\($0).png" } + ["https://example.com/favicon.ico"])
    }

    @Test func vectorAndMaskIconsAreSkipped() throws {
        let html = "<link rel=\"icon\" href=\"/a.svg\"><link rel=\"mask-icon\" href=\"/mask.png\">"
        #expect(try candidates(html) == ["https://example.com/favicon.ico"])
    }

    @Test func pagesWithoutAnIconLinkYieldOnlyTheConventionalFile() throws {
        for html in [nil, "<html><body>hi</body></html>", "<link rel=\"stylesheet\" href=\"/x.css\">"] {
            #expect(try candidates(html) == ["https://example.com/favicon.ico"])
        }
    }
}
