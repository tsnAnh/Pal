import Foundation

public enum EmbedProvider: String, Sendable, CaseIterable {
    case youtube
    case vimeo
    case instagram
    case pinterest
    case tiktok
    case twitter
    case spotify
    case googlemaps
    case openstreetmap
}

public struct EmbedDescriptor: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var provider: EmbedProvider
    public var label: String
    public var sourceURL: URL
    public var embedURL: URL
    public var aspectRatio: Double?
    public var height: Double?
    public var maxWidth: Double?

    public init(
        id: String,
        provider: EmbedProvider,
        label: String,
        sourceURL: URL,
        embedURL: URL,
        aspectRatio: Double? = nil,
        height: Double? = nil,
        maxWidth: Double? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.sourceURL = sourceURL
        self.embedURL = embedURL
        self.aspectRatio = aspectRatio
        self.height = height
        self.maxWidth = maxWidth
    }

    public func embedURL(dark: Bool) -> URL {
        guard provider == .twitter else { return embedURL }
        let themed = embedURL.absoluteString.replacingOccurrences(of: "theme=light", with: dark ? "theme=dark" : "theme=light")
        return URL(string: themed) ?? embedURL
    }
}

public enum EmbedDetector {
    public static let allowedEmbedHosts: Set<String> = [
        "www.youtube-nocookie.com",
        "player.vimeo.com",
        "www.instagram.com",
        "assets.pinterest.com",
        "www.tiktok.com",
        "platform.twitter.com",
        "open.spotify.com",
        "maps.google.com",
        "www.openstreetmap.org",
    ]

    public static func detect(_ url: URL) -> EmbedDescriptor? {
        guard let source = EmbedSource(url) else { return nil }
        let matchers: [(EmbedSource) -> EmbedDescriptor?] = [
            youtube, vimeo, instagram, pinterest, tiktok, twitter, spotify, googleMaps, openStreetMap,
        ]
        let match = matchers.lazy.compactMap { $0(source) }.first
        guard let match, isAllowed(match.embedURL) else { return nil }
        return match
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased(), allowedEmbedHosts.contains(host) else { return false }
        return url.port == nil && url.user() == nil
    }

    private static func make(
        _ source: EmbedSource,
        provider: EmbedProvider,
        label: String,
        id: String,
        embed: String,
        aspectRatio: Double? = nil,
        height: Double? = nil,
        maxWidth: Double
    ) -> EmbedDescriptor? {
        guard let embedURL = URL(string: embed) else { return nil }
        return EmbedDescriptor(
            id: id,
            provider: provider,
            label: label,
            sourceURL: source.url,
            embedURL: embedURL,
            aspectRatio: aspectRatio,
            height: height,
            maxWidth: maxWidth
        )
    }

    private static func youtube(_ source: EmbedSource) -> EmbedDescriptor? {
        var identifier = ""
        switch source.bareHost {
        case "youtu.be":
            identifier = source.segments.first ?? ""
        case "youtube.com", "youtube-nocookie.com":
            let kind = source.segments.first ?? ""
            if kind == "watch" {
                identifier = source.queryValue("v") ?? ""
            } else if ["embed", "shorts", "live", "v"].contains(kind), source.segments.count > 1 {
                identifier = source.segments[1]
            }
        default:
            return nil
        }
        guard isYouTubeID(identifier) else { return nil }
        var embed = "https://www.youtube-nocookie.com/embed/\(identifier)?modestbranding=1&rel=0"
        let primary = source.queryValue("t")
        let raw = primary?.isEmpty == false ? primary : source.queryValue("start")
        if let start = raw.flatMap(startSeconds), start > 0 { embed += "&start=\(start)" }
        return make(source, provider: .youtube, label: "YouTube", id: "youtube:\(identifier)", embed: embed, aspectRatio: 16.0 / 9.0, maxWidth: 640)
    }

    private static func isYouTubeID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 11 && bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D }
    }

    static func startSeconds(_ value: String) -> Int? {
        if isDigits(value) { return value.utf8.count <= 9 ? Int(value) : nil }
        var rest = Substring(value)
        var total = 0
        var lastRank = 0
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9, let amount = Int(digits) else { return nil }
            let unitIndex = rest.index(rest.startIndex, offsetBy: digits.count)
            guard unitIndex < rest.endIndex else { return nil }
            let units: [Character: (rank: Int, multiplier: Int)] = ["h": (1, 3600), "m": (2, 60), "s": (3, 1)]
            guard let unit = units[rest[unitIndex]] else { return nil }
            let (rank, multiplier) = (unit.rank, unit.multiplier)
            guard rank > lastRank else { return nil }
            lastRank = rank
            total += amount * multiplier
            rest = rest[rest.index(after: unitIndex)...]
        }
        return total > 0 ? total : nil
    }

    private static func vimeo(_ source: EmbedSource) -> EmbedDescriptor? {
        guard source.bareHost == "vimeo.com" || source.bareHost == "player.vimeo.com",
              let identifier = source.segments.last(where: isDigits)
        else { return nil }
        return make(
            source, provider: .vimeo, label: "Vimeo", id: "vimeo:\(identifier)",
            embed: "https://player.vimeo.com/video/\(identifier)", aspectRatio: 16.0 / 9.0, maxWidth: 640
        )
    }

    private static func instagram(_ source: EmbedSource) -> EmbedDescriptor? {
        guard source.bareHost == "instagram.com", source.segments.count >= 2 else { return nil }
        let kind = source.segments[0] == "reels" ? "reel" : source.segments[0]
        let code = source.segments[1]
        let valid = !code.isEmpty && code.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D }
        guard ["p", "reel", "tv"].contains(kind), valid else { return nil }
        return make(
            source, provider: .instagram, label: "Instagram", id: "instagram:\(code)",
            embed: "https://www.instagram.com/\(kind)/\(code)/embed", height: 450, maxWidth: 400
        )
    }

    private static func pinterest(_ source: EmbedSource) -> EmbedDescriptor? {
        let labels = source.bareHost.split(separator: ".").map(String.init)
        guard isPinterestHost(labels), source.segments.count >= 2, source.segments[0] == "pin", isDigits(source.segments[1]) else { return nil }
        let identifier = source.segments[1]
        return make(
            source, provider: .pinterest, label: "Pinterest", id: "pinterest:\(identifier)",
            embed: "https://assets.pinterest.com/ext/embed.html?id=\(identifier)", height: 380, maxWidth: 236
        )
    }

    private static func isPinterestHost(_ labels: [String]) -> Bool {
        guard labels.count >= 2, let tld = labels.last else { return false }
        if labels[labels.count - 2] == "pinterest" { return tld.count == 2 || tld == "com" }
        if labels.count >= 3, labels[labels.count - 3] == "pinterest" {
            return (labels[labels.count - 2] == "co" || labels[labels.count - 2] == "com") && tld.count == 2
        }
        return false
    }

    private static func tiktok(_ source: EmbedSource) -> EmbedDescriptor? {
        guard source.bareHost == "tiktok.com",
              let marker = source.segments.firstIndex(of: "video"), marker + 1 < source.segments.count,
              isDigits(source.segments[marker + 1])
        else { return nil }
        let identifier = source.segments[marker + 1]
        return make(
            source, provider: .tiktok, label: "TikTok", id: "tiktok:\(identifier)",
            embed: "https://www.tiktok.com/player/v1/\(identifier)", aspectRatio: 9.0 / 16.0, maxWidth: 365
        )
    }

    private static func twitter(_ source: EmbedSource) -> EmbedDescriptor? {
        guard source.bareHost == "twitter.com" || source.bareHost == "x.com",
              let marker = source.segments.firstIndex(of: "status"), marker + 1 < source.segments.count,
              isDigits(source.segments[marker + 1])
        else { return nil }
        let identifier = source.segments[marker + 1]
        return make(
            source, provider: .twitter, label: "X", id: "twitter:\(identifier)",
            embed: "https://platform.twitter.com/embed/Tweet.html?id=\(identifier)&theme=light&dnt=true", maxWidth: 480
        )
    }

    private static func spotify(_ source: EmbedSource) -> EmbedDescriptor? {
        guard source.bareHost == "open.spotify.com" else { return nil }
        let start = source.segments.first?.hasPrefix("intl-") == true ? 1 : 0
        guard start + 1 < source.segments.count else { return nil }
        let kind = source.segments[start]
        let identifier = source.segments[start + 1]
        let valid = !identifier.isEmpty && identifier.utf8.allSatisfy(isAlphanumeric)
        guard ["album", "artist", "episode", "playlist", "show", "track"].contains(kind), valid else { return nil }
        return make(
            source, provider: .spotify, label: "Spotify", id: "spotify:\(kind):\(identifier)",
            embed: "https://open.spotify.com/embed/\(kind)/\(identifier)", height: 152, maxWidth: 480
        )
    }

    private static func googleMaps(_ source: EmbedSource) -> EmbedDescriptor? {
        let host = source.bareHost
        guard isGoogleHost(host), host.hasPrefix("maps.") || source.path.hasPrefix("/maps") else { return nil }
        var query = ""
        var zoom = ""
        if let fix = parseCoordinates(in: source.path) {
            query = "\(fix.lat),\(fix.lng)"
            zoom = fix.zoom.map { String(Int(($0 + 0.5).rounded(.down))) } ?? ""
        } else if let value = [source.queryValue("q"), source.queryValue("query")].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            query = value
        } else if let place = placeName(in: source.path) {
            query = place
        }
        guard !query.isEmpty, query.utf8.count <= 512 else { return nil }
        let zoomParameter = zoom.isEmpty ? "" : "&z=\(zoom)"
        return make(
            source, provider: .googlemaps, label: "Google Maps",
            id: "googlemaps:\(query)\(zoom.isEmpty ? "" : "@\(zoom)")",
            embed: "https://maps.google.com/maps?output=embed&q=\(formEncode(query))\(zoomParameter)",
            aspectRatio: 16.0 / 10.0, maxWidth: 640
        )
    }

    private static func isGoogleHost(_ host: String) -> Bool {
        if host == "google.com" || host == "maps.google.com" { return true }
        let labels = host.split(separator: ".")
        guard labels.first == "google", let tld = labels.last else { return false }
        if labels.count == 2 { return tld.count == 2 }
        return labels.count == 3 && (labels[1] == "co" || labels[1] == "com") && tld.count == 2
    }

    private static func parseCoordinates(in path: String) -> (lat: String, lng: String, zoom: Double?)? {
        let bytes = Array(path.utf8)
        for start in bytes.indices where bytes[start] == 0x40 {
            guard let lat = scanNumber(bytes, from: start + 1), lat.end < bytes.count, bytes[lat.end] == 0x2C,
                  let lng = scanNumber(bytes, from: lat.end + 1)
            else { continue }
            var zoom: Double?
            if lng.end < bytes.count, bytes[lng.end] == 0x2C, let value = scanNumber(bytes, from: lng.end + 1, allowNegative: false),
               value.end < bytes.count, bytes[value.end] == 0x7A, let parsed = Double(value.text), parsed < 1_000 {
                zoom = parsed
            }
            return (lat.text, lng.text, zoom)
        }
        return nil
    }

    private static func placeName(in path: String) -> String? {
        guard let marker = path.range(of: "/place/") else { return nil }
        let raw = path[marker.upperBound...].prefix { $0 != "/" && $0 != "@" }
        guard !raw.isEmpty else { return nil }
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        guard let decoded = spaced.removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }

    private static func openStreetMap(_ source: EmbedSource) -> EmbedDescriptor? {
        guard source.bareHost == "openstreetmap.org", let fragment = source.fragment, let anchor = fragment.range(of: "map=") else { return nil }
        let bytes = Array(fragment[anchor.upperBound...].utf8)
        guard let zoomNumber = scanNumber(bytes, from: 0, allowNegative: false), zoomNumber.end < bytes.count, bytes[zoomNumber.end] == 0x2F,
              let latNumber = scanNumber(bytes, from: zoomNumber.end + 1), latNumber.end < bytes.count, bytes[latNumber.end] == 0x2F,
              let lngNumber = scanNumber(bytes, from: latNumber.end + 1),
              let zoom = Double(zoomNumber.text), let lat = Double(latNumber.text), let lng = Double(lngNumber.text),
              zoom <= 25, abs(lat) <= 90, abs(lng) <= 180
        else { return nil }
        let lonDelta = 360 / pow(2, zoom)
        let latDelta = lonDelta / 2
        let bbox = [lng - lonDelta / 2, lat - latDelta / 2, lng + lonDelta / 2, lat + latDelta / 2]
            .map { String(format: "%.5f", $0) }
            .joined(separator: ",")
        let marker2 = "\(jsNumber(lat)),\(jsNumber(lng))"
        let embed = "https://www.openstreetmap.org/export/embed.html?bbox=\(formEncode(bbox))&layer=mapnik&marker=\(formEncode(marker2))"
        return make(
            source, provider: .openstreetmap, label: "OpenStreetMap",
            id: "openstreetmap:\(jsNumber(lat)),\(jsNumber(lng))@\(jsNumber(zoom))",
            embed: embed, aspectRatio: 16.0 / 10.0, maxWidth: 640
        )
    }

    private static func jsNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return "\(value)"
    }

    private static func scanNumber(_ bytes: [UInt8], from start: Int, allowNegative: Bool = true) -> (text: String, end: Int)? {
        var cursor = start
        if allowNegative, cursor < bytes.count, bytes[cursor] == 0x2D { cursor += 1 }
        let digitsStart = cursor
        while cursor < bytes.count, isDigit(bytes[cursor]) { cursor += 1 }
        guard cursor > digitsStart else { return nil }
        if cursor + 1 < bytes.count, bytes[cursor] == 0x2E, isDigit(bytes[cursor + 1]) {
            cursor += 1
            while cursor < bytes.count, isDigit(bytes[cursor]) { cursor += 1 }
        }
        return (String(decoding: bytes[start..<cursor], as: UTF8.self), cursor)
    }

    private static func formEncode(_ value: String) -> String {
        var output = ""
        for byte in value.utf8 {
            if isAlphanumeric(byte) || byte == 0x2A || byte == 0x2D || byte == 0x2E || byte == 0x5F {
                output.unicodeScalars.append(Unicode.Scalar(byte))
            } else if byte == 0x20 {
                output += "+"
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy(isDigit)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}

private struct EmbedSource {
    let url: URL
    let bareHost: String
    let path: String
    let segments: [String]
    let fragment: String?
    private let components: URLComponents

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.absoluteString.utf8.count <= 4_096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        if let port = components.port, port != (scheme == "https" ? 443 : 80) { return nil }
        self.url = url
        self.components = components
        self.bareHost = Self.stripSubdomain(host)
        self.path = components.percentEncodedPath
        self.segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        self.fragment = components.percentEncodedFragment
    }

    func queryValue(_ name: String) -> String? {
        guard let item = components.percentEncodedQueryItems?.first(where: { $0.name == name }) else { return nil }
        let spaced = (item.value ?? "").replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    private static func stripSubdomain(_ host: String) -> String {
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            return String(host.dropFirst(prefix.count))
        }
        return host
    }
}
