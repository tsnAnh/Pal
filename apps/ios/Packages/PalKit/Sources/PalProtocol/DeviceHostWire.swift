import Foundation

public struct ShellRunWire: Encodable, Sendable, Equatable {
    public var exitCode: Int?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var truncated: Bool

    public init(exitCode: Int?, stdout: String, stderr: String, timedOut: Bool, truncated: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case exitCode, stdout, stderr, timedOut, truncated
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(stderr, forKey: .stderr)
        try container.encode(timedOut, forKey: .timedOut)
        try container.encode(truncated, forKey: .truncated)
    }
}

public struct FileReadWire: Encodable, Sendable, Equatable {
    public var path: String
    public var content: String
    public var sizeBytes: Int
    public var truncated: Bool

    public init(path: String, content: String, sizeBytes: Int, truncated: Bool) {
        self.path = path
        self.content = content
        self.sizeBytes = sizeBytes
        self.truncated = truncated
    }
}

public struct FileEntryWire: Encodable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var sizeBytes: Int?
    public var modifiedAt: String?

    public init(name: String, kind: String, sizeBytes: Int?, modifiedAt: String?) {
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct FileListWire: Encodable, Sendable, Equatable {
    public var path: String
    public var entries: [FileEntryWire]
    public var truncated: Bool

    public init(path: String, entries: [FileEntryWire], truncated: Bool) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }
}

public struct FileWriteWire: Encodable, Sendable, Equatable {
    public var path: String
    public var bytesWritten: Int

    public init(path: String, bytesWritten: Int) {
        self.path = path
        self.bytesWritten = bytesWritten
    }
}

public struct ScreenCaptureWire: Encodable, Sendable, Equatable {
    public var imageBase64: String
    public var width: Int
    public var height: Int
    public var display: Int
    public var text: String?

    public init(imageBase64: String, width: Int, height: Int, display: Int, text: String?) {
        self.imageBase64 = imageBase64
        self.width = width
        self.height = height
        self.display = display
        self.text = text
    }
}

public struct ScreenReadWire: Encodable, Sendable, Equatable {
    public var text: String
    public var display: Int

    public init(text: String, display: Int) {
        self.text = text
        self.display = display
    }
}

public struct AppWire: Encodable, Sendable, Equatable {
    public var name: String
    public var bundleId: String?
    public var pid: Int
    public var frontmost: Bool

    public init(name: String, bundleId: String?, pid: Int, frontmost: Bool) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.frontmost = frontmost
    }
}

public struct AppsListWire: Encodable, Sendable, Equatable {
    public var apps: [AppWire]
    public var truncated: Bool

    public init(apps: [AppWire], truncated: Bool) {
        self.apps = apps
        self.truncated = truncated
    }
}

public struct AppOpenWire: Encodable, Sendable, Equatable {
    public var app: AppWire
    public var launched: Bool

    public init(app: AppWire, launched: Bool) {
        self.app = app
        self.launched = launched
    }
}

public struct AppQuitWire: Encodable, Sendable, Equatable {
    public var app: AppWire
    public var quitRequested: Bool

    public init(app: AppWire, quitRequested: Bool) {
        self.app = app
        self.quitRequested = quitRequested
    }
}

public struct WindowFrameWire: Encodable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WindowWire: Encodable, Sendable, Equatable {
    public var windowId: Int
    public var app: String
    public var pid: Int
    public var title: String?
    public var frame: WindowFrameWire
    public var onScreen: Bool

    public init(windowId: Int, app: String, pid: Int, title: String?, frame: WindowFrameWire, onScreen: Bool) {
        self.windowId = windowId
        self.app = app
        self.pid = pid
        self.title = title
        self.frame = frame
        self.onScreen = onScreen
    }
}

public struct WindowsListWire: Encodable, Sendable, Equatable {
    public var windows: [WindowWire]
    public var titlesAvailable: Bool
    public var truncated: Bool
    public var note: String?

    public init(windows: [WindowWire], titlesAvailable: Bool, truncated: Bool, note: String?) {
        self.windows = windows
        self.titlesAvailable = titlesAvailable
        self.truncated = truncated
        self.note = note
    }
}

public struct WindowsFocusWire: Encodable, Sendable, Equatable {
    public var app: AppWire
    public var windowId: Int?
    public var raised: Bool
    public var note: String?

    public init(app: AppWire, windowId: Int?, raised: Bool, note: String?) {
        self.app = app
        self.windowId = windowId
        self.raised = raised
        self.note = note
    }
}

public struct ClipboardReadWire: Encodable, Sendable, Equatable {
    public var types: [String]
    public var concealed: Bool
    public var text: String?
    public var imageBase64: String?
    public var imageMime: String?
    public var imageBytes: Int?
    public var truncated: Bool

    public init(types: [String], concealed: Bool, text: String?, imageBase64: String?, imageMime: String?, imageBytes: Int?, truncated: Bool) {
        self.types = types
        self.concealed = concealed
        self.text = text
        self.imageBase64 = imageBase64
        self.imageMime = imageMime
        self.imageBytes = imageBytes
        self.truncated = truncated
    }
}

public struct ClipboardWriteWire: Encodable, Sendable, Equatable {
    public var kind: String
    public var size: Int

    public init(kind: String, size: Int) {
        self.kind = kind
        self.size = size
    }
}
