import CryptoKit
import Foundation
import ImageIO
import Observation
import PalChat
import SwiftUI

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
    private static let storedPixels = 96
    private static let sharpPixels = 48
    private static let diskTimeToLive: TimeInterval = 7 * 24 * 3600
    private static let missTimeToLive: TimeInterval = 3600

    private let session: URLSession
    private let directory: URL
    private var misses: [String: Date] = [:]
    private var inflight: [String: Task<Data?, Never>] = [:]

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        directory: URL = URL.cachesDirectory.appending(path: "favicons", directoryHint: .isDirectory)
    ) {
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        self.directory = directory
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
        let html = await body(of: root, limit: Self.htmlLimit).flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
        var best: (data: Data, pixels: Int)?
        for candidate in FaviconOrigin.iconCandidates(inHTML: html, rootURL: root) where Self.isAllowed(candidate, for: host) {
            guard let data = await body(of: candidate, limit: Self.iconLimit), let icon = Self.normalized(data),
                  icon.pixels > best?.pixels ?? 0
            else { continue }
            best = icon
            if icon.pixels >= Self.sharpPixels { break }
        }
        return best?.data
    }

    private static func isAllowed(_ url: URL, for host: String) -> Bool {
        guard url.scheme?.lowercased() == "https", let target = url.host(percentEncoded: false)?.lowercased() else { return false }
        return FaviconOrigin.isPublicHostname(target) && FaviconOrigin.isSameSite(target, as: host)
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

    private static func normalized(_ data: Data) -> (data: Data, pixels: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let widths = (0..<CGImageSourceGetCount(source)).map { index in
            (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        guard let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: storedPixels,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, largest, options as CFDictionary),
              let png = PlatformImage(cgImage: thumbnail).pngData()
        else { return nil }
        return (png, max(thumbnail.width, thumbnail.height))
    }

    private func path(_ host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest)-\(Self.storedPixels).png")
    }

    private func readDisk(_ host: String) -> Data? {
        let url = path(host)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.diskTimeToLive
        else { return nil }
        return try? Data(contentsOf: url) // perf-lint: ok actor-isolated, runs off the main actor
    }

    private func writeDisk(_ host: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: path(host), options: .atomic)
    }
}

@MainActor
final class FaviconCache {
    static let shared = FaviconCache(load: fetched)

    private static let maxUpscale: CGFloat = 1.6

    private nonisolated static func fetched(host: String) async -> Data? {
        await FaviconFetcher.shared.iconData(forHost: host)
    }

    fileprivate struct Rendering: Hashable {
        let points: CGFloat
        let scale: CGFloat
    }

    @MainActor @Observable
    final class Slot {
        fileprivate(set) var source: CGImage? // perf-lint: ok set once per host when its icon arrives, never per frame
        @ObservationIgnored fileprivate var rounded: [Rendering: PlatformImage] = [:]
    }

    private var slots: [String: Slot] = [:]
    private let load: @Sendable (String) async -> Data?

    init(load: @escaping @Sendable (String) async -> Data?) {
        self.load = load
    }

    func image(for url: URL, pointSize: CGFloat, scale: CGFloat) -> PlatformImage? {
        guard let host = FaviconOrigin.host(of: url) else { return nil }
        let slot = entry(for: host)
        guard let source = slot.source else { return nil }
        let rendering = Rendering(points: pointSize, scale: scale)
        if let cached = slot.rounded[rendering] { return cached }
        guard CGFloat(max(source.width, source.height)) * Self.maxUpscale >= (pointSize * scale).rounded() else { return nil }
        let icon = source.roundedIcon(points: pointSize, scale: scale) // perf-lint: ok drawn once per host, size and scale, then cached
        slot.rounded[rendering] = icon
        return icon
    }

    private func entry(for host: String) -> Slot {
        if let existing = slots[host] { return existing }
        let slot = Slot()
        slots[host] = slot
        Task { [load] in
            guard let data = await load(host), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            slot.source = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return slot
    }
}

extension EnvironmentValues {
    @Entry var faviconCache: FaviconCache?
}
