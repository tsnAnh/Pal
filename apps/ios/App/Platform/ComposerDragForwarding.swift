#if os(macOS)
import AppKit
import ObjectiveC
import PalChat

private struct ObjectBox: @unchecked Sendable {
    let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }
}

@MainActor
enum ComposerDragForwarding {
    private static var subclasses: [ObjectIdentifier: AnyClass] = [:]
    private static weak var engaged: NSTextView?
    private static var restoreClass: AnyClass?

    static func update(isFocused: Bool) {
        guard isFocused else { return release() }
        Task { engage() }
    }

    private static func engage() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, engaged !== editor,
              let base = object_getClass(editor), !NSStringFromClass(base).hasPrefix("NSKVONotifying_")
        else { return }
        release()
        guard let forwarding = forwardingClass(for: base) else { return }
        restoreClass = base
        engaged = editor
        object_setClass(editor, forwarding)
    }

    private static func release() {
        if let editor = engaged, let restoreClass { object_setClass(editor, restoreClass) }
        engaged = nil
        restoreClass = nil
    }

    private static func forwardingClass(for base: AnyClass) -> AnyClass? {
        if let cached = subclasses[ObjectIdentifier(base)] { return cached }
        guard let created = objc_allocateClassPair(base, "PalDragForwarding_" + NSStringFromClass(base), 0) else { return nil }
        install(on: created, base: base)
        objc_registerClassPair(created)
        subclasses[ObjectIdentifier(base)] = created
        return created
    }

    private nonisolated static func forwarded<Result: Sendable>(
        _ editor: AnyObject,
        _ info: AnyObject,
        _ forward: @MainActor (NSDraggingDestination, NSDraggingInfo) -> Result
    ) -> Result? {
        let editorBox = ObjectBox(editor)
        let infoBox = ObjectBox(info)
        return MainActor.assumeIsolated {
            guard let sender = infoBox.object as? NSDraggingInfo else { return nil }
            let identifiers = sender.draggingPasteboard.types?.map(\.rawValue) ?? []
            guard DropSource.carriesAttachment(typeIdentifiers: identifiers) else { return nil }
            var view = (editorBox.object as? NSView)?.superview
            while let current = view {
                if !current.registeredDraggedTypes.isEmpty, let host = current as? NSDraggingDestination { return forward(host, sender) }
                view = current.superview
            }
            return nil
        }
    }

    private nonisolated static func install(on subclass: AnyClass, base: AnyClass) {
        typealias OperationIMP = @convention(c) (AnyObject, Selector, AnyObject) -> UInt
        typealias VoidIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias BoolIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

        func operation(_ selector: Selector, _ forward: @escaping @MainActor (NSDraggingDestination, NSDraggingInfo) -> NSDragOperation) {
            let original = unsafeBitCast(class_getMethodImplementation(base, selector), to: OperationIMP.self)
            let block: @convention(block) (AnyObject, AnyObject) -> UInt = { editor, info in
                if let handled = forwarded(editor, info, { forward($0, $1).rawValue }) { return handled }
                return original(editor, selector, info)
            }
            class_addMethod(subclass, selector, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), "Q@:@")
        }

        func notification(_ selector: Selector, _ forward: @escaping @MainActor (NSDraggingDestination, NSDraggingInfo) -> Void) {
            let original = unsafeBitCast(class_getMethodImplementation(base, selector), to: VoidIMP.self)
            let block: @convention(block) (AnyObject, AnyObject) -> Void = { editor, info in
                if forwarded(editor, info, forward) == nil { original(editor, selector, info) }
            }
            class_addMethod(subclass, selector, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), "v@:@")
        }

        func decision(_ selector: Selector, _ forward: @escaping @MainActor (NSDraggingDestination, NSDraggingInfo) -> Bool) {
            let original = unsafeBitCast(class_getMethodImplementation(base, selector), to: BoolIMP.self)
            let block: @convention(block) (AnyObject, AnyObject) -> Bool = { editor, info in
                if let handled = forwarded(editor, info, forward) { return handled }
                return original(editor, selector, info)
            }
            class_addMethod(subclass, selector, imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), "B@:@")
        }

        operation(#selector(NSDraggingDestination.draggingEntered(_:))) { $0.draggingEntered?($1) ?? [] }
        operation(#selector(NSDraggingDestination.draggingUpdated(_:))) { $0.draggingUpdated?($1) ?? [] }
        notification(#selector(NSDraggingDestination.draggingExited(_:))) { $0.draggingExited?($1) }
        decision(#selector(NSDraggingDestination.prepareForDragOperation(_:))) { $0.prepareForDragOperation?($1) ?? true }
        decision(#selector(NSDraggingDestination.performDragOperation(_:))) { $0.performDragOperation?($1) ?? false }
        notification(#selector(NSDraggingDestination.concludeDragOperation(_:))) { $0.concludeDragOperation?($1) }
    }
}
#else
enum ComposerDragForwarding {
    static func update(isFocused: Bool) {}
}
#endif
