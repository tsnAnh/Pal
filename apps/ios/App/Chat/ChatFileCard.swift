import PalChat
import PalDesign
import SwiftUI

struct ChatFileActions: Sendable {
    let check: @Sendable (FileReference) async throws -> FileAvailability
    let load: @Sendable (FileReference) async throws -> Data
}

private struct ChatFileActionsKey: EnvironmentKey {
    static let defaultValue: ChatFileActions? = nil
}

private struct ChatFileOpenerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (FileReference) -> Void)? = nil
}

extension EnvironmentValues {
    var chatFileActions: ChatFileActions? {
        get { self[ChatFileActionsKey.self] }
        set { self[ChatFileActionsKey.self] = newValue }
    }

    var chatFileOpener: (@MainActor (FileReference) -> Void)? {
        get { self[ChatFileOpenerKey.self] }
        set { self[ChatFileOpenerKey.self] = newValue }
    }
}

struct ChatFileStack: View {
    let files: [FileReference]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files) { file in
                DocumentFileCard(file: file, kind: FileCardKind(fileName: file.name), isStreaming: isStreaming)
            }
        }
        .accessibilityIdentifier("chatFileStack")
    }
}
