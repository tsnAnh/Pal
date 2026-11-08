import Foundation
import HermesChat
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

    @Test func iconLinkIsResolvedAgainstTheRoot() throws {
        let root = try #require(URL(string: "https://example.com/"))
        let html = "<html><head><link rel=\"stylesheet\" href=\"/a.css\"><link rel='shortcut icon' href='/static/fav.png'></head>"
        #expect(FaviconOrigin.iconHref(inHTML: html, rootURL: root) == URL(string: "https://example.com/static/fav.png"))
    }

    @Test func appleTouchIconIsOnlyAFallbackForARealIcon() throws {
        let root = try #require(URL(string: "https://example.com/"))
        let both = "<link rel=\"apple-touch-icon\" href=\"/touch.png\"><link rel=\"icon\" href=\"/real.ico\">"
        #expect(FaviconOrigin.iconHref(inHTML: both, rootURL: root) == URL(string: "https://example.com/real.ico"))
        let onlyTouch = "<link rel=\"apple-touch-icon\" href=\"/touch.png\">"
        #expect(FaviconOrigin.iconHref(inHTML: onlyTouch, rootURL: root) == URL(string: "https://example.com/touch.png"))
    }

    @Test func pagesWithoutAnIconLinkYieldNothing() throws {
        let root = try #require(URL(string: "https://example.com/"))
        #expect(FaviconOrigin.iconHref(inHTML: "<html><body>hi</body></html>", rootURL: root) == nil)
        #expect(FaviconOrigin.iconHref(inHTML: "<link rel=\"stylesheet\" href=\"/x.css\">", rootURL: root) == nil)
    }
}
