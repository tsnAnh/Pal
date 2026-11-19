import CoreGraphics
import Foundation

public enum ViewerAction: Sendable, Equatable, CaseIterable {
    case edit
    case download
    case close
}

public enum ViewerContent: Sendable, Equatable {
    case image(ConversationImage)

    public var actions: [ViewerAction] {
        switch self {
        case .image: [.edit, .download, .close]
        }
    }
}

public enum ViewerTitle {
    public static func choose(name: String, messageText: String?) -> String {
        guard isGeneric(name), let line = firstLine(of: messageText) else { return name }
        return line
    }

    public static func isGeneric(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces).lowercased()
        if stem.isEmpty { return true }
        return stem.range(of: genericStem, options: .regularExpression) != nil
            || stem.range(of: identifier, options: .regularExpression) != nil
    }

    static func firstLine(of text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private static let genericStem = "^(?:img|image|photo|picture|pic|screenshot|screen shot|dsc|dscn|pxl|mvimg|file|attachment|untitled|unnamed)"
        + "(?:[ _-]?[0-9][0-9 _.-]*(?: at [0-9. :]+(?: ?(?:am|pm))?)?)?$"
    private static let identifier = "^(?:[0-9a-f-]{8,}|[0-9]+)$"
}

public enum ViewerCaption {
    public static func text(name: String, pixelSize: CGSize?) -> String {
        guard let size = pixelSize, size.width > 0, size.height > 0 else { return name }
        return "\(name) · \(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

public extension ImageViewerState {
    var content: ViewerContent { .image(current) }

    var title: String { ViewerTitle.choose(name: current.reference.name, messageText: current.messageText) }

    var showsStepper: Bool { images.count > 1 }

    var positionLabel: String? {
        showsStepper ? String(localized: "\(index + 1) of \(images.count)") : nil
    }
}

public enum ViewerGeometry {
    public static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let factor = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }
}

public struct ViewerZoom: Equatable, Sendable {
    public static let range: ClosedRange<CGFloat> = 1...6
    public static let doubleClickMinimum: CGFloat = 2

    public private(set) var scale: CGFloat = 1
    public private(set) var offset: CGSize = .zero

    public init() {}

    public var isZoomed: Bool { scale > 1 }

    public mutating func magnify(by factor: CGFloat) {
        setScale(scale * factor)
    }

    public mutating func setScale(_ value: CGFloat) {
        scale = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        if !isZoomed { offset = .zero }
    }

    public mutating func pan(to proposed: CGSize, fitted: CGSize, viewport: CGSize) {
        guard isZoomed else {
            offset = .zero
            return
        }
        let limitX = max(0, (fitted.width * scale - viewport.width) / 2)
        let limitY = max(0, (fitted.height * scale - viewport.height) / 2)
        offset = CGSize(
            width: min(max(proposed.width, -limitX), limitX),
            height: min(max(proposed.height, -limitY), limitY)
        )
    }

    public mutating func toggleActualSize(pixelSize: CGSize, fitted: CGSize) {
        if isZoomed {
            reset()
            return
        }
        guard fitted.width > 0 else { return }
        setScale(max(pixelSize.width / fitted.width, Self.doubleClickMinimum))
    }

    public mutating func reset() {
        scale = 1
        offset = .zero
    }
}

public struct ViewerComposerState: Equatable, Sendable {
    public static let editHint = "Describe the change"

    public var draft = ""
    public private(set) var attachedImageID: String?
    public private(set) var hint: String?
    public private(set) var focusRequests = 0

    public init() {}

    public mutating func edit(_ image: ConversationImage) {
        attachedImageID = image.id
        hint = Self.editHint
        focusRequests += 1
    }

    public func placeholder(title: String) -> String {
        hint ?? "Message about “\(title)”"
    }
}

public enum ImageViewerSend {
    public struct Submission: Equatable, Sendable {
        public let image: ConversationImage
        public let text: String
    }

    public static func submit(_ state: ImageViewerState, composer: ViewerComposerState) -> (submission: Submission, viewer: ImageViewerState?)? {
        let text = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = state.images.first { $0.id == composer.attachedImageID } ?? state.current
        return (Submission(image: image, text: text), nil)
    }
}
