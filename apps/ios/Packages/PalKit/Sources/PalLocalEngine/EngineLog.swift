import Foundation
import Synchronization

public final class FileEngineLog: EngineLogging {
    private let url: URL
    private let handle = Mutex<FileHandle?>(nil)

    public init(url: URL) {
        self.url = url
    }

    public func write(_ line: String) {
        handle.withLock { current in
            if current == nil { current = openForAppend() }
            guard let current else { return }
            try? current.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    private func openForAppend() -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}
