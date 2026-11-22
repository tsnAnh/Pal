#if os(macOS)
import AppKit
import PalChat
import PalDesign
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import Pal

@MainActor
private final class IntakeCalls {
    var batches: [DropBatch] = []
    var continuation: CheckedContinuation<Void, Never>?
}

@MainActor
private func drop(_ providers: [NSItemProvider]) async -> [DropBatch] {
    let calls = IntakeCalls()
    var accepted = false
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        calls.continuation = continuation
        accepted = AttachmentIntake.receive(providers) { batch in
            calls.batches.append(batch)
            calls.continuation?.resume()
            calls.continuation = nil
        }
        if !accepted {
            calls.continuation = nil
            continuation.resume()
        }
    }
    try? await Task.sleep(for: .milliseconds(150))
    return calls.batches
}

private func pngData() throws -> Data {
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
    let tiff = try #require(image.tiffRepresentation)
    return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
}

private func dataProvider(_ identifier: String, _ data: Data) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

private func temporaryFile(_ name: String, _ contents: String = "hello") throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "intake-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name)
    try Data(contents.utf8).write(to: url)
    return url
}

@MainActor
@Suite("Attachment intake")
struct AttachmentIntakeTests {
    @Test("a Finder file reaches the intake once, as a file")
    func fileURL() async throws {
        let url = try temporaryFile("note.txt")
        let batches = await drop([NSItemProvider(object: url as NSURL)])
        #expect(batches.count == 1)
        #expect(batches.first?.files.map(\.lastPathComponent) == ["note.txt"])
        #expect(batches.first?.failures.isEmpty == true)
    }

    @Test("several Finder files are one intake call with every file")
    func multipleFiles() async throws {
        let urls = try [temporaryFile("a.txt"), temporaryFile("b.txt"), temporaryFile("c.pdf")]
        let batches = await drop(urls.map { NSItemProvider(object: $0 as NSURL) })
        #expect(batches.count == 1)
        #expect(batches.first?.files.count == 3)
    }

    @Test("image data of every common representation becomes an image")
    func imageRepresentations() async throws {
        let png = try pngData()
        for identifier in ["public.png", "public.jpeg", "public.tiff", "public.heic", "org.webmproject.webp"] {
            let batches = await drop([dataProvider(identifier, png)])
            #expect(batches.count == 1, "\(identifier)")
            #expect(batches.first?.images.count == 1, "\(identifier)")
            #expect(batches.first?.failures.isEmpty == true, "\(identifier)")
        }
    }

    @Test("a promised document is copied to a temporary folder the intake owns")
    func promisedContent() async throws {
        let source = try temporaryFile("report.pdf")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: "com.adobe.pdf", fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let batches = await drop([provider])
        let batch = try #require(batches.first)
        #expect(batch.files.map(\.lastPathComponent) == ["report.pdf"])
        #expect(batch.temporaryDirectories.count == 1)
        #expect(FileManager.default.fileExists(atPath: batch.files[0].path))
        batch.temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    @Test("a web address alone is reported, not dropped silently")
    func webLinkOnly() async throws {
        let provider = NSItemProvider(object: try #require(URL(string: "https://example.com/photo.png")) as NSURL)
        let batches = await drop([provider])
        #expect(batches.count == 1)
        #expect(batches.first?.failures == [.webLinkOnly])
        #expect(batches.first?.files.isEmpty == true)
    }

    @Test("an unknown item is reported as unsupported")
    func unsupported() async {
        let batches = await drop([dataProvider("com.example.unknown-card", Data("x".utf8))])
        #expect(batches.first?.failures == [.unsupported])
    }

    @Test("plain text is not taken, so the text field keeps it")
    func text() async {
        let batches = await drop([NSItemProvider(object: "hello" as NSString)])
        #expect(batches.isEmpty)
    }

    @Test("an image and a file in one drag are still one intake call")
    func mixedDrop() async throws {
        let url = try temporaryFile("note.txt")
        let batches = await drop([NSItemProvider(object: url as NSURL), dataProvider("public.png", try pngData())])
        #expect(batches.count == 1)
        #expect(batches.first?.files.count == 1)
        #expect(batches.first?.images.count == 1)
    }
}

@MainActor
private final class BodyCounter {
    var count = 0
    var panes = 0
}

private struct CountingRow: View {
    let counter: BodyCounter

    var body: some View {
        let _ = counter.count += 1 // swiftlint:disable:this redundant_discardable_let
        Text("row")
    }
}

private struct Pane: View {
    let counter: BodyCounter
    let targeting: DropTargeting

    var body: some View {
        let _ = counter.panes += 1 // swiftlint:disable:this redundant_discardable_let
        VStack {
            Text("header")
            ScrollView { LazyVStack { ForEach(0..<20, id: \.self) { _ in CountingRow(counter: counter).equatable() } } }
            Text("composer")
        }
        .attachmentIntake(botName: "Ada", accent: nil, intake: { _ in }, targeting: targeting)
    }
}

extension CountingRow: Equatable {
    nonisolated static func == (lhs: CountingRow, rhs: CountingRow) -> Bool { true }
}

@MainActor
@Suite("Drop overlay")
struct DropOverlayTests {
    @Test("the title names the bot, and several items say how many")
    func copy() {
        #expect(DropOverlayCopy.title(count: 1, botName: "Ada") == "Drop to attach to Ada")
        #expect(DropOverlayCopy.title(count: 0, botName: "Ada") == "Drop to attach to Ada")
        #expect(DropOverlayCopy.title(count: 3, botName: "Ada") == "Drop 3 files to attach to Ada")
        #expect(DropOverlayCopy.subtitle == "Images and files")
    }

    @Test("a bot with an accent colours the overlay, a bot without one stays neutral")
    func tint() {
        let accent = BotAccent(name: "ada", meta: nil)
        #expect(DropOverlayTint.resolve(accent: accent).isNeutral == false)
        #expect(DropOverlayTint.resolve(accent: nil).isNeutral)
        #expect(DropOverlayTint.resolve(accent: nil).glyph == PalTokens.textSecondary)
        #expect(DropOverlayTint.resolve(accent: accent).glyph == BubblePalette.ink(accent: accent))
    }

    @Test("a failed attachment notice goes away on its own after four seconds")
    func noticeDuration() {
        #expect(ChatModel.attachmentNoticeDuration == .seconds(4))
    }

    @Test("toggling the drop highlight reruns no row body")
    func overlayDoesNotRerunRows() async throws {
        let counter = BodyCounter()
        let targeting = DropTargeting()
        let host = NSHostingView(rootView: Pane(counter: counter, targeting: targeting))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let settled = counter.count
        let settledPanes = counter.panes
        #expect(settled > 0)
        for _ in 0..<5 {
            targeting.isTargeted = true
            try await Task.sleep(for: .milliseconds(80))
            targeting.isTargeted = false
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(counter.count == settled)
        #expect(counter.panes == settledPanes)
    }
}
#endif
