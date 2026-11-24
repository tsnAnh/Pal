#if os(macOS)
import AppKit
import ImageIO
import PalChat
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WebKit

@testable import Pal

@MainActor @Observable
private final class MatrixState {
    var findOpen = false
    var streaming = false
    var draft = ""
}

private struct MatrixMessage: NSViewRepresentable {
    func makeNSView(context: Context) -> PassiveTextView {
        let view = PassiveTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.string = "A message in the transcript"
        return view
    }

    func updateNSView(_ view: PassiveTextView, context: Context) {}
}

private enum MatrixLayout {
    static let width: CGFloat = 520
    static let height: CGFloat = 520
    static let findBarY: CGFloat = 18
    static let messagesY: CGFloat = 96
    static let imageRowY: CGFloat = 196
    static let embedY: CGFloat = 296
    static let composerY: CGFloat = 500
    static let centerX: CGFloat = 260
}

private struct MatrixPane: View {
    @Bindable var state: MatrixState
    let image: NSImage

    private static let descriptor = EmbedDescriptor(
        id: "matrix",
        provider: .youtube,
        label: "Matrix",
        sourceURL: URL(string: "https://youtu.be/matrix")!,
        embedURL: URL(string: "https://www.youtube-nocookie.com/embed/matrix")!,
        height: 120
    )

    var body: some View {
        VStack(spacing: 0) {
            if state.findOpen {
                TextField("Find", text: .constant("")).frame(height: 36)
            } else {
                Color.clear.frame(height: 36)
            }
            MatrixMessage().frame(height: 120)
            Image(nsImage: image).resizable().frame(height: 80)
            EmbedWebView(descriptor: Self.descriptor, dark: false, onFailure: {}).frame(height: 120)
            if state.streaming {
                ProgressView().frame(height: 24)
            } else {
                Color.clear.frame(height: 24)
            }
            Spacer(minLength: 0)
            TextField("Message", text: $state.draft, axis: .vertical).frame(height: 40)
        }
        .frame(width: MatrixLayout.width, height: MatrixLayout.height)
        .attachmentIntake(botName: "Matrix", accent: nil, intake: { _ in })
    }
}

private final class MatrixWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private func settle(_ seconds: Double = 0.3) {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end { RunLoop.main.run(mode: .default, before: end) }
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
private final class MatrixRig {
    let state = MatrixState()
    let window: NSWindow
    let hosting: NSHostingView<MatrixPane>

    init(image: NSImage) {
        hosting = NSHostingView(rootView: MatrixPane(state: state, image: image))
        window = MatrixWindow(
            contentRect: CGRect(x: 0, y: 0, width: MatrixLayout.width, height: MatrixLayout.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.hasShadow = false
        window.contentView = hosting
        window.orderFrontRegardless()
        settle()
    }

    func close() {
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    func textField(lowest: Bool) -> NSTextField? {
        let fields = descendants(of: hosting).compactMap { $0 as? NSTextField }
        let rank: (NSTextField) -> CGFloat = { $0.convert($0.bounds, to: self.hosting).midY }
        return lowest ? fields.max { rank($0) < rank($1) } : fields.min { rank($0) < rank($1) }
    }

    func windowPoint(top: CGFloat) -> NSPoint {
        let y = hosting.isFlipped ? top : hosting.bounds.height - top
        return hosting.convert(NSPoint(x: MatrixLayout.centerX, y: y), to: nil)
    }
}

private enum MatrixPaneState: String, CaseIterable {
    case composerFocusedWithText = "composer focused+text"
    case composerUnfocused = "composer unfocused"
    case overMessages = "over messages"
    case overEmbed = "over web embed"
    case overImageRow = "over image row"
    case findBarOpen = "find bar open"
    case streaming = "while streaming"

    var pointTop: CGFloat {
        switch self {
        case .composerFocusedWithText, .composerUnfocused, .streaming: MatrixLayout.composerY
        case .overMessages: MatrixLayout.messagesY
        case .overEmbed: MatrixLayout.embedY
        case .overImageRow: MatrixLayout.imageRowY
        case .findBarOpen: MatrixLayout.findBarY
        }
    }

    @MainActor func prepare(_ rig: MatrixRig) {
        switch self {
        case .composerFocusedWithText:
            rig.state.draft = "hello"
            settle()
            if let field = rig.textField(lowest: true) { rig.window.makeFirstResponder(field) }
        case .findBarOpen:
            rig.state.findOpen = true
            settle()
            if let field = rig.textField(lowest: false) { rig.window.makeFirstResponder(field) }
        case .streaming:
            rig.state.streaming = true
        case .composerUnfocused, .overMessages, .overEmbed, .overImageRow:
            break
        }
        settle()
    }
}

@MainActor
private func registers(_ view: NSView, for offered: [String]) -> Bool {
    view.registeredDraggedTypes.contains { registered in
        offered.contains { type in
            type == registered.rawValue
                || (UTType(type).flatMap { offeredType in UTType(registered.rawValue).map { offeredType.conforms(to: $0) } } ?? false)
        }
    }
}

@MainActor
private func frameClaimant(_ view: NSView, at point: NSPoint, offered: [String]) -> NSView? {
    for sub in view.subviews.reversed() where !sub.isHidden {
        let local = sub.convert(point, from: view)
        if sub.bounds.contains(local), let found = frameClaimant(sub, at: local, offered: offered) { return found }
    }
    return registers(view, for: offered) ? view : nil
}

@MainActor
private func hitClaimant(in window: NSWindow, at windowPoint: NSPoint, offered: [String]) -> NSView? {
    guard let content = window.contentView, let frame = content.superview else { return nil }
    var current = content.hitTest(frame.convert(windowPoint, from: nil))
    while let view = current {
        if registers(view, for: offered) { return view }
        current = view.superview
    }
    return nil
}

@MainActor
private func shortName(_ view: NSView?) -> String {
    guard let view else { return "none" }
    let name = String(reflecting: type(of: view))
    return String(name.prefix { $0 != "<" }).split(separator: ".").last.map(String.init) ?? name
}

@MainActor
private func verdict(_ view: NSView?) -> String {
    switch view {
    case nil: "nobody"
    case is NSTextView, is WKWebView, is NSTextField: "EATEN"
    default: "pane"
    }
}

private final class MatrixPromiseDelegate: NSObject, @preconcurrency NSFilePromiseProviderDelegate, @unchecked Sendable {
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

private struct MatrixSource {
    let name: String
    let attaches: Bool
    let write: @MainActor (NSPasteboard) -> Void
}

@MainActor
private final class MatrixFixtures {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.tsnanh.pal.drop-matrix"))
    let directory = FileManager.default.temporaryDirectory.appending(path: "drop-matrix-\(UUID().uuidString)", directoryHint: .isDirectory)
    var delegates: [MatrixPromiseDelegate] = []
    let image: NSImage
    let bitmap: NSBitmapImageRep
    let png: Data

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        bitmap = try #require(NSBitmapImageRep(data: tiff))
        png = try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func encoded(_ type: UTType) -> Data {
        guard let cgImage = bitmap.cgImage else { return png }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : png
    }

    private func file(_ name: String, _ contents: Data) -> URL {
        let url = directory.appending(path: name)
        try? contents.write(to: url)
        return url
    }

    private func single(_ pasteboard: NSPasteboard, _ build: (NSPasteboardItem) -> Void) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        build(item)
        pasteboard.writeObjects([item])
    }

    private func promise(_ pasteboard: NSPasteboard, type: UTType, name: String, data: Data) {
        let delegate = MatrixPromiseDelegate(data: data, name: name)
        delegates.append(delegate)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)])
    }

    var sources: [MatrixSource] {
        let pdf = Data("%PDF-1.1\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF".utf8)
        return [
            MatrixSource(name: "Finder file URL", attaches: true) { pasteboard in
                let url = self.file("note.png", self.png)
                self.single(pasteboard) {
                    $0.setString(url.absoluteString, forType: .fileURL)
                    $0.setString(url.lastPathComponent, forType: .string)
                }
            },
            MatrixSource(name: "PNG data", attaches: true) { pasteboard in self.single(pasteboard) { $0.setData(self.png, forType: .png) } },
            MatrixSource(name: "JPEG data", attaches: true) { pasteboard in
                self.single(pasteboard) { $0.setData(self.encoded(.jpeg), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) }
            },
            MatrixSource(name: "HEIC data", attaches: true) { pasteboard in
                self.single(pasteboard) { $0.setData(self.encoded(.heic), forType: NSPasteboard.PasteboardType(UTType.heic.identifier)) }
            },
            MatrixSource(name: "TIFF data", attaches: true) { pasteboard in
                self.single(pasteboard) { $0.setData(self.bitmap.tiffRepresentation ?? self.png, forType: .tiff) }
            },
            MatrixSource(name: "screenshot thumbnail (promise)", attaches: true) { pasteboard in
                self.promise(pasteboard, type: .png, name: "Screenshot.png", data: self.png)
            },
            MatrixSource(name: "Safari/Chrome image (url+html+image)", attaches: true) { pasteboard in
                self.single(pasteboard) {
                    $0.setString("https://example.com/photo.png", forType: .URL)
                    $0.setString("https://example.com/photo.png", forType: .string)
                    $0.setString("<img src=\"https://example.com/photo.png\">", forType: .html)
                    $0.setData(self.png, forType: .png)
                }
            },
            MatrixSource(name: "Photos (promise)", attaches: true) { pasteboard in
                self.promise(pasteboard, type: .jpeg, name: "IMG_0001.jpeg", data: self.encoded(.jpeg))
            },
            MatrixSource(name: "PDF Finder file", attaches: true) { pasteboard in
                let url = self.file("report.pdf", pdf)
                self.single(pasteboard) {
                    $0.setString(url.absoluteString, forType: .fileURL)
                    $0.setString(url.lastPathComponent, forType: .string)
                }
            },
            MatrixSource(name: "PDF data only", attaches: true) { pasteboard in self.single(pasteboard) { $0.setData(pdf, forType: .pdf) } },
            MatrixSource(name: "plain text", attaches: false) { pasteboard in self.single(pasteboard) { $0.setString("hello", forType: .string) } },
        ]
    }
}

@MainActor
@Suite("Attachment drop matrix", .serialized)
struct AttachmentDropMatrixTests {
    @Test("every drag source against every pane state: who claims the drag")
    func matrix() throws {
        let fixtures = try MatrixFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures.directory) }
        var frameRows: [String] = []
        var hitRows: [String] = []
        var rigs: [(MatrixPaneState, MatrixRig)] = []
        for state in MatrixPaneState.allCases {
            let rig = MatrixRig(image: fixtures.image)
            state.prepare(rig)
            rigs.append((state, rig))
        }
        defer { rigs.forEach { $0.1.close() } }
        let registered = rigs.first.map { rig in
            ([rig.1.hosting as NSView] + descendants(of: rig.1.hosting)).filter { !$0.registeredDraggedTypes.isEmpty }
                .map { "\(shortName($0)): \($0.registeredDraggedTypes.map(\.rawValue))" }
        } ?? []
        for source in fixtures.sources {
            source.write(fixtures.pasteboard)
            let offered = fixtures.pasteboard.pasteboardItems?.flatMap { $0.types.map(\.rawValue) } ?? []
            #expect(!offered.isEmpty, "\(source.name) wrote nothing to the pasteboard")
            var frameCells: [String] = []
            var hitCells: [String] = []
            for (state, rig) in rigs {
                let point = rig.windowPoint(top: state.pointTop)
                let frame = rig.window.contentView.flatMap { frameClaimant($0, at: $0.convert(point, from: nil), offered: offered) }
                let hit = hitClaimant(in: rig.window, at: point, offered: offered)
                frameCells.append("\(verdict(frame)):\(shortName(frame))")
                hitCells.append("\(verdict(hit)):\(shortName(hit))")
            }
            frameRows.append("\(source.name) | " + frameCells.joined(separator: " | "))
            hitRows.append("\(source.name) | " + hitCells.joined(separator: " | "))
        }
        let header = "source | " + MatrixPaneState.allCases.map(\.rawValue).joined(separator: " | ")
        let report = """
        pane registered drag types: \(registered)
        == claimant by frame order (deepest registered view under the point, front to back) ==
        \(header)
        \(frameRows.joined(separator: "\n"))
        == claimant by hit test (hitTest, then superviews) ==
        \(header)
        \(hitRows.joined(separator: "\n"))
        """
        print(report)
        let url = FileManager.default.temporaryDirectory.appending(path: "pal-drop-matrix.txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        print("drop matrix written to \(url.path)")
        #expect(frameRows.count == fixtures.sources.count)
    }
}
#endif
