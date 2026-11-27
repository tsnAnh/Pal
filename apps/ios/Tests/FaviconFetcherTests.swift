import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Pal

private final class IconSite: URLProtocol, @unchecked Sendable {
    static let pages = Mutex<[String: Data]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Self.pages.withLock { $0[url.absoluteString] }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func square(_ side: Int) -> Data {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func ico(_ sides: [Int]) -> Data {
    func little(_ value: Int, bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    let frames = sides.map(square)
    var directory = Data(little(0, bytes: 2) + little(1, bytes: 2) + little(sides.count, bytes: 2))
    var offset = 6 + 16 * sides.count
    for (side, frame) in zip(sides, frames) {
        directory.append(contentsOf: little(side % 256, bytes: 1) + little(side % 256, bytes: 1) + [0, 0])
        directory.append(contentsOf: little(1, bytes: 2) + little(32, bytes: 2) + little(frame.count, bytes: 4) + little(offset, bytes: 4))
        offset += frame.count
    }
    return frames.reduce(directory, +)
}

@Suite("The site icon is fetched at the highest size the site offers")
struct FaviconFetcherTests {
    private func width(of site: [String: Data]) async -> Int? {
        let host = "s\(UUID().uuidString.lowercased()).demo.com"
        IconSite.pages.withLock { pages in
            for (path, body) in site { pages["https://\(host)\(path)"] = body }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IconSite.self]
        let directory = FileManager.default.temporaryDirectory.appending(path: "favicon-fetcher-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetcher = FaviconFetcher(configuration: configuration, directory: directory)
        guard let data = await fetcher.iconData(forHost: host),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image.width
    }

    private func page(_ links: String) -> Data {
        Data("<html><head>\(links)</head></html>".utf8)
    }

    @Test("the largest frame of an ico file wins whatever its position", arguments: [[64, 32, 16], [16, 64, 32], [16, 32, 64]])
    func largestFrame(sides: [Int]) async {
        let got = await width(of: ["/favicon.ico": ico(sides)])
        print("MEASURE fetch ico \(sides) received \(got ?? 0)px")
        #expect(got == 64)
    }

    @Test("a larger declared icon link wins over the first one listed")
    func largestDeclaredLink() async {
        let got = await width(of: [
            "/": page("<link rel=\"icon\" href=\"/a.png\" sizes=\"32x32\"><link rel=\"icon\" href=\"/b.png\" sizes=\"144x144\">"),
            "/a.png": square(32),
            "/b.png": square(144),
        ])
        print("MEASURE fetch links 32,144 received \(got ?? 0)px")
        #expect(got == 96)
    }

    @Test("a touch icon replaces a plain icon too small to be sharp")
    func touchIconBeatsSmallIcon() async {
        let got = await width(of: [
            "/": page("<link rel=\"icon\" href=\"/a.ico\"><link rel=\"apple-touch-icon\" href=\"/touch.png\">"),
            "/a.ico": ico([16]),
            "/touch.png": square(180),
        ])
        print("MEASURE fetch 16 plus touch 180 received \(got ?? 0)px")
        #expect(got == 96)
    }

    @Test("a sharp plain icon stays ahead of a larger touch icon")
    func sharpPlainIconStays() async {
        let got = await width(of: [
            "/": page("<link rel=\"icon\" href=\"/a.ico\"><link rel=\"apple-touch-icon\" href=\"/touch.png\">"),
            "/a.ico": ico([48, 32, 16]),
            "/touch.png": square(180),
        ])
        #expect(got == 48)
    }

    @Test("a vector link that cannot be decoded falls back to the site's raster icon")
    func vectorLinkFallsBack() async {
        let got = await width(of: [
            "/": page("<link rel=\"icon\" type=\"image/svg+xml\" href=\"/a.svg\">"),
            "/a.svg": Data("<svg/>".utf8),
            "/favicon.ico": ico([64]),
        ])
        #expect(got == 64)
    }
}
