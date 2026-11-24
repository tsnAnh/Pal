import Foundation

public enum FileCardKind: Sendable, Equatable {
    case document(ChatDocumentKind)
    case archive
    case model3D
    case other

    public init(fileName: String) {
        if let document = ChatDocumentKind(fileName: fileName) {
            self = .document(document)
            return
        }
        switch MediaKind(fileName: fileName) {
        case .archive: self = .archive
        case .model3D: self = .model3D
        case .image, .video, .audio, .pdf, .document, .other: self = .other
        }
    }

    public var documentKind: ChatDocumentKind? {
        if case .document(let kind) = self { kind } else { nil }
    }

    public var hasThumbnail: Bool {
        switch self {
        case .document, .model3D: true
        case .archive, .other: false
        }
    }

    public var spokenName: String {
        switch self {
        case .document(let kind): kind.spokenName
        case .archive: "Archive"
        case .model3D: "3D model"
        case .other: "File"
        }
    }

    public var iconName: String {
        switch self {
        case .document(let kind): kind.iconName
        case .archive: "doc.zipper"
        case .model3D: "cube"
        case .other: "doc"
        }
    }

    public func typeLabel(of file: FileReference) -> String {
        switch self {
        case .archive, .model3D: spokenName
        case .document, .other: file.typeLabel
        }
    }
}

public struct FileCardResolver: Sendable {
    public let media: MediaPreviewResolver
    public let documents: DocumentPreviewResolver

    public init(media: MediaPreviewResolver, documents: DocumentPreviewResolver) {
        self.media = media
        self.documents = documents
    }

    public init(media: MediaPreviewResolver) {
        self.init(media: media, documents: DocumentPreviewResolver(source: media.source, cache: media.cache))
    }

    public var source: any MediaAssetSource { media.source }

    public func cached(_ reference: MediaReference, kind: FileCardKind) -> MediaPreview? {
        kind.hasThumbnail ? documents.cached(reference) : media.cached(reference)
    }

    public func resolve(_ reference: MediaReference, kind: FileCardKind) async throws -> MediaPreviewState {
        guard kind.hasThumbnail else { return try await media.resolve(reference) }
        return try await documents.resolve(reference, kind: kind.documentKind)
    }
}
