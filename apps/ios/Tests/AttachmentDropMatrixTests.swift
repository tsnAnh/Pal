#if os(macOS)
import AppKit
import PalChat
import SwiftUI
import Testing
import UniformTypeIdentifiers

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
private func verdict(_ view: NSView?, _ pasteboard: NSPasteboard) -> String {
    switch view {
    case nil: "nobody"
    case let ours as AttachmentDropView: ours.decide("enter", pasteboard) == [] ? "REFUSED" : "ok"
    default: "EATEN"
    }
}

@MainActor
private final class MatrixDelivery {
    var batch: DropBatch?
}

@MainActor
private func deliver(_ pasteboard: NSPasteboard, attaches: Bool) async throws -> String {
    let delivery = MatrixDelivery()
    let taken = AttachmentIntake.receive(payloads: AttachmentDropView.payloads(from: pasteboard)) { delivery.batch = $0 }
    #expect(taken == attaches, "receive returned \(taken)")
    guard taken else { return "not taken" }
    for _ in 0..<40 where delivery.batch == nil { try await Task.sleep(for: .milliseconds(100)) }
    guard let batch = delivery.batch else {
        Issue.record("the intake never delivered a batch")
        return "NEVER DELIVERED"
    }
    defer { batch.temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) } }
    #expect(batch.failures.isEmpty && batch.files.count + batch.images.count >= 1, "batch \(batch.failures.map(\.label))")
    return "files=\(batch.files.count) images=\(batch.images.count) failures=\(batch.failures.map(\.label))"
}

@MainActor
private func claimantRows(_ fixtures: MatrixFixtures, _ rigs: [(MatrixPaneState, MatrixRig)]) -> ([String], [String]) {
    var frameRows: [String] = []
    var hitRows: [String] = []
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
            let frameCell = "\(verdict(frame, fixtures.pasteboard)):\(shortName(frame))"
            frameCells.append(frameCell)
            hitCells.append("\(verdict(hit, fixtures.pasteboard)):\(shortName(hit))")
            #expect(frameCell.hasPrefix("ok:") == source.attaches, "\(source.name) over \(state.rawValue): \(frameCell)")
        }
        frameRows.append("\(source.name) | " + frameCells.joined(separator: " | "))
        hitRows.append("\(source.name) | " + hitCells.joined(separator: " | "))
    }
    return (frameRows, hitRows)
}

@MainActor
@Suite("Attachment drop matrix", .serialized)
struct AttachmentDropMatrixTests {
    @Test("every drag source against every pane state: every attaching drag reaches the one destination and delivers")
    func matrix() async throws {
        let fixtures = try MatrixFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures.directory) }
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
        let (frameRows, hitRows) = claimantRows(fixtures, rigs)
        var deliveryRows: [String] = []
        for source in fixtures.sources {
            source.write(fixtures.pasteboard)
            let outcome = try await deliver(fixtures.pasteboard, attaches: source.attaches)
            deliveryRows.append("\(source.name) | \(outcome)")
        }
        let header = "source | " + MatrixPaneState.allCases.map(\.rawValue).joined(separator: " | ")
        let report = """
        pane registered drag types: \(registered)
        == claimant by frame order (deepest registered view under the point, front to back) ==
        \(header)
        \(frameRows.joined(separator: "\n"))
        == claimant by hit test (hitTest, then superviews; informational, a row that differs from the table above is the risk case) ==
        \(header)
        \(hitRows.joined(separator: "\n"))
        == delivery to the intake (files, images, failures) ==
        \(deliveryRows.joined(separator: "\n"))
        """
        print(report)
        let url = FileManager.default.temporaryDirectory.appending(path: "pal-drop-matrix.txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        print("drop matrix written to \(url.path)")
        #expect(frameRows.count == fixtures.sources.count)
    }
}
#endif
