import CryptoKit
import Foundation
import ImageIO
import Observation
import PalChat

private final class FaviconRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let origin = task.originalRequest?.url?.host(percentEncoded: false)?.lowercased(),
              let target = request.url, target.scheme?.lowercased() == "https",
              let targetHost = target.host(percentEncoded: false)?.lowercased(),
              FaviconOrigin.isPublicHostname(targetHost), FaviconOrigin.isSameSite(targetHost, as: origin)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor FaviconFetcher {
    static let shared = FaviconFetcher()

    private static let htmlLimit = 96 * 1024
    private static let iconLimit = 256 * 1024
    private static let diskTimeToLive: TimeInterval = 7 * 24 * 3600
    private static let missTimeToLive: TimeInterval = 3600

    private let session: URLSession
    private let directory: URL
    private var misses: [String: Date] = [:]
    private var inflight: [String: Task<Data?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        directory = URL.cachesDirectory.appending(path: "favicons", directoryHint: .isDirectory)
    }

    func iconData(forHost host: String) async -> Data? {
        if let cached = readDisk(host) { return cached }
        if let missed = misses[host], Date().timeIntervalSince(missed) < Self.missTimeToLive { return nil }
        if let running = inflight[host] { return await running.value }
        let task = Task { await fetch(host) }
        inflight[host] = task
        let data = await task.value
        inflight[host] = nil
        if let data {
            writeDisk(host, data)
        } else {
            misses[host] = Date()
        }
        return data
    }

    private func fetch(_ host: String) async -> Data? {
        guard let root = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let html = await body(of: root, limit: Self.htmlLimit).flatMap({ String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }),
           let href = FaviconOrigin.iconHref(inHTML: html, rootURL: root),
           href.scheme?.lowercased() == "https",
           let hrefHost = href.host(percentEncoded: false)?.lowercased(),
           FaviconOrigin.isPublicHostname(hrefHost),
           FaviconOrigin.isSameSite(hrefHost, as: host)
        {
            candidates.append(href)
        }
        if let conventional = URL(string: "https://\(host)/favicon.ico") { candidates.append(conventional) }
        for candidate in candidates {
            if let data = await body(of: candidate, limit: Self.iconLimit), let normalized = Self.normalized(data) { return normalized }
        }
        return nil
    }

    private func body(of url: URL, limit: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/*,text/html;q=0.8", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: FaviconRedirectGuard())
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let finalHost = http.url?.host(percentEncoded: false)?.lowercased(),
                  http.url?.scheme?.lowercased() == "https",
                  let originalHost = url.host(percentEncoded: false)?.lowercased(),
                  FaviconOrigin.isSameSite(finalHost, as: originalHost)
            else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
            return data
        } catch {
            return nil
        }
    }

    private static func normalized(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetCount(source) - 1, options as CFDictionary) else { return nil }
        return PlatformImage(cgImage: thumbnail).pngData()
    }

    private func path(_ host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).png")
    }

    private func readDisk(_ host: String) -> Data? {
        let url = path(host)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.diskTimeToLive
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private func writeDisk(_ host: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: path(host), options: .atomic)
    }
}

@MainActor
@Observable
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    func image(for url: URL, pointSize: CGFloat) -> PlatformImage? {
        guard let host = FaviconOrigin.host(of: url) else { return nil }
        if let image = images[host] { return image.roundedIcon(points: pointSize) }
        if requested.insert(host).inserted {
            Task {
                guard let data = await FaviconFetcher.shared.iconData(forHost: host), let image = PlatformImage(data: data) else { return }
                images[host] = image
            }
        }
        return nil
    }
}
