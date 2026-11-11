#if os(macOS)
import Foundation

public struct SystemFiles: FilesProviding {
    private static let maximumScannedNames = 100_000

    public init() {}

    public func read(path rawPath: String, captureLimit: Int) async throws -> FileReadRecord {
        let path = try DevicePath.resolve(rawPath)
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PosixError.map(errno, path: path, action: "read") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw PosixError.map(errno, path: path, action: "read") }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFDIR { throw DeviceProviderError.invalidArgs("\(path) is a folder. List it instead of reading it.") }
        guard kind == S_IFREG else { throw DeviceProviderError.invalidArgs("\(path) is not a regular file.") }
        let keep = captureLimit + DeviceTextLimit.slack
        var bytes = [UInt8](repeating: 0, count: keep)
        var filled = 0
        while filled < keep {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + filled, keep - filled) }
            if count > 0 { filled += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw PosixError.map(errno, path: path, action: "read") }
            break
        }
        bytes.removeLast(keep - filled)
        let size = max(Int(info.st_size), filled)
        return FileReadRecord(path: path, content: TextCap.capture(bytes, totalBytes: size, limit: captureLimit), sizeBytes: size)
    }

    public func list(path rawPath: String, limit: Int) async throws -> FileListRecord {
        let path = try DevicePath.resolve(rawPath)
        var info = stat()
        guard stat(path, &info) == 0 else { throw PosixError.map(errno, path: path, action: "list") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DeviceProviderError.invalidArgs("\(path) is not a folder.") }
        guard access(path, R_OK) == 0 else { throw PosixError.map(errno, path: path, action: "list") }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch {
            throw PosixError.map(error, path: path, action: "list")
        }
        let scanned = names.prefix(Self.maximumScannedNames).sorted()
        let entries = scanned.prefix(limit).map { entry(named: $0, in: path) }
        return FileListRecord(path: path, entries: Array(entries), truncated: names.count > limit)
    }

    public func write(path rawPath: String, content: String, append: Bool, createDirs: Bool) async throws -> FileWriteRecord {
        let path = try DevicePath.resolve(rawPath)
        if createDirs {
            let parent = (path as NSString).deletingLastPathComponent
            do { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch {
                throw PosixError.map(error, path: parent, action: "create")
            }
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), mode_t(0o644))
        guard descriptor >= 0 else { throw PosixError.map(errno, path: path, action: "write") }
        defer { close(descriptor) }
        let data = Array(content.utf8)
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + written, data.count - written) }
            if count > 0 { written += count; continue }
            if count < 0, errno == EINTR { continue }
            throw PosixError.map(count < 0 ? errno : EIO, path: path, action: "write")
        }
        return FileWriteRecord(path: path, bytesWritten: written)
    }

    private func entry(named name: String, in directory: String) -> FileEntryRecord {
        var info = stat()
        guard lstat(directory + "/" + name, &info) == 0 else { return FileEntryRecord(name: name, kind: .other) }
        let kind: FileEntryKind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileEntryRecord(
            name: name, kind: kind, sizeBytes: kind == .file ? Int(info.st_size) : nil, modified: Date(timeIntervalSince1970: seconds)
        )
    }
}
#endif
