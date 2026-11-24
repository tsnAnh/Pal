#if os(macOS)
import AppKit
import Foundation
import ImageIO
import PalChat
import Testing
import UniformTypeIdentifiers

@testable import Pal

struct ImageLayoutFrame {
    let index: Int
    let phase: String
    let offset: Double
    let insetBottom: Double
    let contentHeight: Double
    let viewportHeight: Double
    let nativeDistance: Double
    let machineDistance: Double
    let state: String
    let button: Bool
    let lastRowBottom: Double?
    let composerTop: Double?
    let image: CGSize?

    var clearance: Double? {
        guard let lastRowBottom, let composerTop else { return nil }
        return composerTop - lastRowBottom
    }

    var aspect: Double? { image.map { $0.height > 0 ? Double($0.width / $0.height) : 0 } }

    static let header = "frame,phase,offset_y,inset_bottom,content_h,viewport_h,native_distance,machine_distance,state,button,"
        + "last_row_bottom,composer_top,clearance,image_w,image_h,image_aspect"

    var csv: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
        let fields = [
            String(index), phase, number(offset), number(insetBottom), number(contentHeight), number(viewportHeight),
            number(nativeDistance), number(machineDistance), state, button ? "1" : "0",
            number(lastRowBottom), number(composerTop), number(clearance),
            number(image.map { Double($0.width) }), number(image.map { Double($0.height) }), number(aspect),
        ]
        return fields.joined(separator: ",")
    }
}

private enum ImageFixture {
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: max(8, width / 10), height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct AccessibilityNode {
    let identifier: String
    let frame: CGRect
}

@MainActor
private final class ImageLayoutStage {
    static let rowIdentifiers: Set<String> = ["userBubble", "assistantBubble", "chatImageGrid", "thinkingLine"]

    let model: ChatModel
    let host: MacChatBenchHost
    let draft = MacChatBenchDraft()
    let scroll = ChatScrollController()
    var world: RebuildWorld = {
        var world = OpenJumpFixture.world(100..<160)
        world.nextKey = 3_000
        return world
    }()
    var phase = "open"
    private(set) var frames: [ImageLayoutFrame] = []
    private var version: UInt64 = 10
    private var sent = 0

    init() async throws {
        let environment = try MacChatBenchSession.environment()
        model = environment.model
        host = MacChatBenchHost(root: environment.surface(draft: draft, scroll: scroll), size: MacChatBench.pane)
        try await Task.sleep(for: .milliseconds(20))
        model.apply(world.snapshot(version: version))
        try await step(30)
        host.settleAtNewest(maxFrames: 240)
    }

    func push() {
        version += 1
        model.apply(world.snapshot(version: version))
    }

    private func nodes() -> [AccessibilityNode] {
        var found: [AccessibilityNode] = []
        func walk(_ node: Any) {
            guard let object = node as? NSObject else { return }
            if object.responds(to: Selector(("accessibilityIdentifier"))), object.responds(to: Selector(("accessibilityFrame"))),
               let identifier = object.value(forKey: "accessibilityIdentifier") as? String, !identifier.isEmpty,
               let screen = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, let window = host.view.window {
                let local = host.view.convert(window.convertFromScreen(screen), from: nil)
                found.append(AccessibilityNode(identifier: identifier, frame: local))
            }
            guard object.responds(to: Selector(("accessibilityChildren"))),
                  let children = object.value(forKey: "accessibilityChildren") as? [Any] else { return }
            children.forEach(walk)
        }
        walk(host.view)
        return found
    }

    func sample() -> ImageLayoutFrame? {
        guard let scrollView = host.transcriptScrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let offset = Double(clip.bounds.origin.y)
        let newest = Double(document.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        let tree = nodes()
        let rows = tree.filter { Self.rowIdentifiers.contains($0.identifier) }
        return ImageLayoutFrame(
            index: frames.count, phase: phase, offset: offset, insetBottom: Double(scrollView.contentInsets.bottom),
            contentHeight: Double(document.frame.height), viewportHeight: Double(clip.bounds.height),
            nativeDistance: max(0, newest - offset), machineDistance: scroll.machine.distanceFromBottom ?? -1,
            state: scroll.machine.state.name, button: scroll.showsJumpButton,
            lastRowBottom: rows.map { Double($0.frame.maxY) }.max(),
            composerTop: tree.first { $0.identifier == "composerField" }.map { Double($0.frame.minY) },
            image: tree.filter { $0.identifier == "chatImage" }.max { $0.frame.minY < $1.frame.minY }?.frame.size
        )
    }

    func step(_ count: Int = 1) async throws {
        for _ in 0..<count {
            try await Task.sleep(for: .seconds(MacChatBench.framePeriod))
            guard let frame = sample() else { throw MacChatBenchError.noTranscriptScrollView }
            frames.append(frame)
        }
    }

    func send(text: String, delivery: TranscriptItem.Delivery = .sending) async throws {
        sent += 1
        phase = "send"
        world.append(rebuildUser("u\(sent)", text, delivery: delivery, at: rebuildAt(30_000 + Double(sent) * 10)))
        world.isRunning = true
        push()
        draft.text = ""
        scroll.sent(animated: true)
        try await step(8)
    }

    func confirmLastSend() {
        guard let index = world.rows.lastIndex(where: { $0.item.id == "u\(sent)" }), case .user(let text, _) = world.rows[index].item.content else { return }
        world.rows[index].item = rebuildUser("u\(sent)", text, delivery: .sent, at: rebuildAt(30_000 + Double(sent) * 10))
        push()
    }

    func streamReply(frames count: Int = 30) async throws {
        phase = "stream"
        var text = "[reply \(sent)] Looking at it now."
        world.append(rebuildAssistant("s\(sent)", text, streaming: true, at: rebuildAt(30_005 + Double(sent) * 10)))
        push()
        for index in 0..<count {
            text += MacChatBenchFixture.streamDelta(at: index)
            let grown = text
            world.editLast { $0.content = .assistant(text: grown, reasoning: "", isStreaming: true) }
            draft.text = Array(repeating: "draft line", count: 1 + index * 6 / count).joined(separator: "\n")
            push()
            try await step()
        }
        let finished = text
        world.editLast { $0.content = .assistant(text: finished, reasoning: "", isStreaming: false) }
        world.isRunning = false
        draft.text = ""
        push()
        try await step(20)
    }

    func settle(_ label: String) async throws -> ImageLayoutFrame {
        phase = label
        host.settleAtNewest(maxFrames: 240)
        try await step(10)
        return try #require(frames.last)
    }

    func writeCSV() {
        guard let directory = MacChatBench.output else { return }
        let body = ([ImageLayoutFrame.header] + frames.map(\.csv)).joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: directory.appending(path: "image-layout-frames.csv"), atomically: true, encoding: .utf8)
    }
}

@MainActor
@Suite("Mac chat image layout", .serialized, .enabled(if: MacChatBench.output != nil))
struct MacChatImageLayoutTests {
    private struct Source {
        let name: String
        let width: Int
        let height: Int
    }

    private static let sources = [
        Source(name: "wide", width: 1772, height: 550), Source(name: "landscape", width: 1300, height: 1000),
        Source(name: "portrait", width: 1000, height: 1600),
    ]

    @Test("a sent image keeps its whole picture at its ratio, the newest row clears the composer and the button stays hidden at the bottom")
    func imageThenText() async throws {
        let stage = try await ImageLayoutStage()
        defer { stage.host.close() }
        var problems: [String] = []

        func check(_ label: String, source: (width: Int, height: Int)? = nil) async throws {
            let frame = try await stage.settle(label)
            if let source {
                let want = Double(source.width) / Double(source.height)
                if let aspect = frame.aspect, let size = frame.image {
                    if abs(aspect - want) > want * 0.03 { problems.append("\(label): image aspect \(aspect) want \(want)") }
                    if size.width > 640.5 { problems.append("\(label): image wider than the bubble column: \(size.width)") }
                } else {
                    problems.append("\(label): no image tile in the accessibility tree")
                }
            }
            if abs(frame.machineDistance - frame.nativeDistance) > 1.5 {
                problems.append("\(label): machine distance \(frame.machineDistance) native \(frame.nativeDistance)")
            }
            if let clearance = frame.clearance, clearance < -0.5 { problems.append("\(label): newest row \(-clearance) pt under the composer") }
            if frame.nativeDistance <= ChatScrollMachine.hideDistance, frame.button { problems.append("\(label): jump button shown at the bottom") }
        }

        for source in Self.sources {
            let path = "/tmp/pal-image-layout-\(source.name).png"
            stage.model.keepLocalImage(try ImageFixture.png(width: source.width, height: source.height), forHostPath: path)
            try await stage.send(text: "[Image attached at: \(path)]")
            try await check("\(source.name)-pending", source: (source.width, source.height))
            stage.confirmLastSend()
            try await check("\(source.name)-persisted", source: (source.width, source.height))
            try await stage.streamReply()
            try await check("\(source.name)-after-reply", source: (source.width, source.height))
        }

        let long = Array(repeating: "A long message that wraps over several lines in the bubble and keeps going.", count: 6).joined(separator: " ")
        try await stage.send(text: long)
        try await check("text-pending")
        try await stage.streamReply()
        try await check("text-after-reply")
        stage.writeCSV()

        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")))
    }
}
#endif
