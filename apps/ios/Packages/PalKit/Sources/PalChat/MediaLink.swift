import Foundation

public enum MediaLink {
    private static let inlineExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8"]
    private static let recognisedExtensions: Set<String> = inlineExtensions.union(["webm", "mkv", "avi"])
    private static let inlineSchemes: Set<String> = ["http", "https", "file"]

    public static func isInlinePlayableVideo(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), inlineSchemes.contains(scheme) else { return false }
        return inlineExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isVideoLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), inlineSchemes.contains(scheme) else { return false }
        return recognisedExtensions.contains(url.pathExtension.lowercased())
    }
}
