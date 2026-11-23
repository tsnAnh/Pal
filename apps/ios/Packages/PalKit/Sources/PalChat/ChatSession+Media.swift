import Foundation

extension ChatSession {
    public func mediaPreview(ref: String) async throws -> MediaPreviewAnswer {
        try await assetAPI().libraryMediaPreview(ref: ref)
    }

    public func mediaChunk(ref: String, offset: Int, length: Int) async throws -> MediaChunk {
        try await assetAPI().libraryMediaChunk(ref: ref, offset: offset, length: length)
    }
}
