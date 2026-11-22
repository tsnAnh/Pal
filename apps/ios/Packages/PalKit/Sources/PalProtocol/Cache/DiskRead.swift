import Foundation

public enum DiskRead {
    @concurrent
    public static func data(contentsOf url: URL, options: Data.ReadingOptions = []) async throws -> Data {
        try Data(contentsOf: url, options: options)
    }

    @concurrent
    public static func json(contentsOf url: URL) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    @concurrent
    public static func text(contentsOf url: URL) async throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
