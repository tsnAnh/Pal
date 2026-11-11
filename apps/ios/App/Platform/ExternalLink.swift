import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ExternalLinkRecorder {
    static let argument = "-hermes-record-external-links"
    static let shared = ExternalLinkRecorder()

    private(set) var opened: [URL] = []

    func record(_ url: URL) { opened.append(url) }
}

@MainActor
enum ExternalLink {
    static var opener: @MainActor (URL) -> Bool = ExternalLink.systemOpen

    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        if ProcessInfo.processInfo.arguments.contains(ExternalLinkRecorder.argument) {
            ExternalLinkRecorder.shared.record(url)
            return true
        }
        return opener(url)
    }

    private static func systemOpen(_ url: URL) -> Bool {
        #if os(iOS)
        UIApplication.shared.open(url)
        return true
        #elseif os(macOS)
        return NSWorkspace.shared.open(url)
        #endif
    }
}

struct ExternalLinkProbe: View {
    private let recorder = ExternalLinkRecorder.shared

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(ExternalLinkRecorder.argument) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel(recorder.opened.last?.absoluteString ?? "")
                .accessibilityValue("\(recorder.opened.count)")
                .accessibilityIdentifier("externalLinkProbe")
                .allowsHitTesting(false)
        }
    }
}
