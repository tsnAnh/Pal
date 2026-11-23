import Foundation
import PalProtocol

struct LibraryMediaPayload: Decodable {
    var dataBase64: String?
    var kind: String?
    var mime: String?
    var size: Int?
    var total: Int?
    var offset: Int?
    var durationSeconds: Double?
    var width: Int?
    var height: Int?
    var previewUnavailable: String?

    enum CodingKeys: String, CodingKey {
        case dataBase64 = "data_base64"
        case kind
        case mime
        case size
        case total
        case offset
        case durationSeconds = "duration_seconds"
        case width
        case height
        case previewUnavailable = "preview_unavailable"
    }
}

extension SessionAPI {
    public func libraryMediaPreview(ref: String) async throws -> MediaPreviewAnswer {
        let result = try await call("library.asset", [
            "asset_ref": .string(ref),
            "preview": .bool(true),
        ])
        let wire = try decode(LibraryMediaPayload.self, result, "library.asset")
        let metadata = MediaMetadata(
            size: wire.size ?? wire.total, duration: wire.durationSeconds, width: wire.width, height: wire.height
        )
        if let reason = wire.previewUnavailable { return .unavailable(reason: reason, metadata) }
        guard let encoded = wire.dataBase64, let poster = Data(base64Encoded: encoded), !poster.isEmpty else {
            return .unavailable(reason: "no_poster", metadata)
        }
        return .poster(poster, metadata)
    }

    public func libraryMediaChunk(ref: String, offset: Int, length: Int) async throws -> MediaChunk {
        let result = try await call("library.asset", [
            "asset_ref": .string(ref),
            "thumbnail": .bool(false),
            "offset": .int(offset),
            "length": .int(length),
        ])
        let wire = try decode(LibraryMediaPayload.self, result, "library.asset")
        guard let encoded = wire.dataBase64, let data = Data(base64Encoded: encoded), let total = wire.total else {
            throw ChatError.unexpectedResponse(method: "library.asset")
        }
        return MediaChunk(data: data, offset: wire.offset ?? offset, total: total)
    }
}
