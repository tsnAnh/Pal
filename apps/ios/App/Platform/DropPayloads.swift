#if os(macOS)
import AppKit
import PalChat
import Synchronization
import UniformTypeIdentifiers

@MainActor
protocol DropPayload {
    var typeIdentifiers: [String] { get }
    func fileURL() async -> URL?
    func data(identifier: String) async -> Data?
    func copiedFile(identifier: String) async -> (file: URL, directory: URL)?
}

private func makeDropDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "pal-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
struct ProviderPayload: DropPayload {
    let provider: NSItemProvider

    var typeIdentifiers: [String] { provider.registeredTypeIdentifiers }

    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    func data(identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data?.isEmpty == false ? data : nil)
            }
        }
    }

    func copiedFile(identifier: String) async -> (file: URL, directory: URL)? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                do {
                    let directory = try makeDropDirectory()
                    let destination = directory.appending(path: url.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: (destination, directory))
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

@MainActor
struct PasteboardItemPayload: DropPayload {
    let item: NSPasteboardItem

    var typeIdentifiers: [String] { item.types.map(\.rawValue) }

    func fileURL() async -> URL? {
        guard let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL else { return nil }
        return url.filePathURL ?? url
    }

    func data(identifier: String) async -> Data? {
        let bytes = item.data(forType: NSPasteboard.PasteboardType(identifier))
        return bytes?.isEmpty == false ? bytes : nil
    }

    func copiedFile(identifier: String) async -> (file: URL, directory: URL)? {
        guard let bytes = await data(identifier: identifier) else { return nil }
        let pathExtension = UTType(identifier)?.preferredFilenameExtension.map { "." + $0 } ?? ""
        do {
            let directory = try makeDropDirectory()
            let file = directory.appending(path: "attachment" + pathExtension)
            do {
                try bytes.write(to: file)
                return (file, directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        } catch {
            return nil
        }
    }
}

private final class FirstDelivery: Sendable {
    private let state = Mutex(false)

    func claim() -> Bool {
        state.withLock { claimed in
            let isFirst = !claimed
            claimed = true
            return isFirst
        }
    }
}

@MainActor
struct PromisePayload: DropPayload {
    let receiver: NSFilePromiseReceiver

    var typeIdentifiers: [String] {
        let types = receiver.fileTypes
        return types.isEmpty || DropSource.classify(typeIdentifiers: types) == .text ? ["public.data"] : types
    }

    func fileURL() async -> URL? { nil }

    func data(identifier: String) async -> Data? {
        guard let copy = await copiedFile(identifier: identifier) else { return nil }
        defer { try? FileManager.default.removeItem(at: copy.directory) }
        let file = copy.file
        let bytes = await Task.detached { FileManager.default.contents(atPath: file.path) }.value
        return bytes?.isEmpty == false ? bytes : nil
    }

    func copiedFile(identifier: String) async -> (file: URL, directory: URL)? {
        guard let directory = try? makeDropDirectory() else { return nil }
        let first = FirstDelivery()
        let received: URL? = await withCheckedContinuation { continuation in
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: .main) { url, error in
                guard first.claim() else { return }
                continuation.resume(returning: error == nil ? url : nil)
            }
        }
        guard let received else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return (received, directory)
    }
}
#endif
