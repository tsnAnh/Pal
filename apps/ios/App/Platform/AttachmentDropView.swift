#if os(macOS)
import AppKit
import PalChat
import SwiftUI

@MainActor
final class AttachmentDropView: NSView {
    static let registeredTypes: [NSPasteboard.PasteboardType] =
        (DropSource.registeredTypeIdentifiers + NSFilePromiseReceiver.readableDraggedTypes).map { NSPasteboard.PasteboardType($0) }

    var targeting: DropTargeting?
    var intake: IntakeHandler?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.registeredTypes)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(Self.registeredTypes)
    }

    static func items(of pasteboard: NSPasteboard) -> [[String]] {
        pasteboard.pasteboardItems?.map { $0.types.map(\.rawValue) } ?? []
    }

    static func payloads(from pasteboard: NSPasteboard) -> [any DropPayload] {
        let items = pasteboard.pasteboardItems ?? []
        var payloads: [any DropPayload] = items
            .filter { !DropSource.isFilePromise(typeIdentifiers: $0.types.map(\.rawValue)) }
            .map { PasteboardItemPayload(item: $0) as any DropPayload }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        payloads += receivers.map { PromisePayload(receiver: $0) as any DropPayload }
        return payloads
    }

    private var destination: String {
        "AttachmentDropView[\(registeredDraggedTypes.map(\.rawValue).joined(separator: ","))]"
    }

    func decide(_ stage: String, _ pasteboard: NSPasteboard) -> NSDragOperation {
        let items = Self.items(of: pasteboard)
        let accepted = DropSource.acceptsDrag(items: items)
        DropTrace.note(
            stage, items: items, destination: destination,
            verdict: accepted ? "accept" : "refuse", refusal: accepted ? nil : DropSource.refusal(items: items)
        )
        if accepted, stage == "enter" { targeting?.itemCount = max(1, items.count) }
        targeting?.isTargeted = accepted
        return accepted ? .copy : []
    }

    func finish(_ pasteboard: NSPasteboard) -> Bool {
        _ = decide("perform", pasteboard)
        DropTrace.reset()
        targeting?.isTargeted = false
        guard let intake else {
            DropTrace.note("perform", items: Self.items(of: pasteboard), destination: destination, verdict: "refuse", refusal: "no-intake")
            return false
        }
        return AttachmentIntake.receive(payloads: Self.payloads(from: pasteboard), intake: intake)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropTrace.reset()
        return decide("enter", sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        decide("update", sender.draggingPasteboard)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropTrace.note("exit", items: [], destination: destination, verdict: "exit")
        DropTrace.reset()
        targeting?.isTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        decide("prepare", sender.draggingPasteboard) != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        finish(sender.draggingPasteboard)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        targeting?.isTargeted = false
    }
}

struct AttachmentDropAnchor: NSViewRepresentable {
    let targeting: DropTargeting
    let intake: IntakeHandler

    func makeNSView(context: Context) -> AttachmentDropView {
        let view = AttachmentDropView(frame: .zero)
        view.targeting = targeting
        view.intake = intake
        return view
    }

    func updateNSView(_ view: AttachmentDropView, context: Context) {
        view.targeting = targeting
        view.intake = intake
    }
}
#endif
