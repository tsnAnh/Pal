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
                ChatFileCard(file: file, isStreaming: isStreaming)
            }
        }
        .accessibilityIdentifier("chatFileStack")
    }
}

struct ChatFileCard: View {
    let file: FileReference
    let isStreaming: Bool

    @Environment(\.chatFileActions) private var actions
    @Environment(\.chatFileOpener) private var opener
    @Environment(\.hermesTheme) private var theme
    @State private var phase: FileCardPhase = .checking
    @State private var attempt = 0
    @State private var isSaving = false
    @State private var notice: String?

    private static let probeAttempts = 3
    private static let probeDelay: Duration = .seconds(2)

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PalMetrics.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                PalIcon("doc", ink: .secondary)
                    .font(.system(size: 22))
                details
                Spacer(minLength: 8)
                trailing
            }
            .padding(10)
            .background(Color(theme.palette.groupedCard), in: shape)
            .contentShape(shape)
            .onTapGesture {
                if phase == .ready { opener?(file) }
            }
            if let notice {
                Text(notice)
                    .hermesText(.timestamp)
                    .foregroundStyle(Color(theme.palette.textSecondary))
                    .accessibilityIdentifier("chatFileNotice")
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatFileCard")
        .task(id: "\(file.id)#\(attempt)#\(isStreaming)") { await check() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(theme.palette.textPrimary))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .hermesText(.timestamp)
                .foregroundStyle(Color(theme.palette.textSecondary))
                .lineLimit(2)
        }
    }

    private var subtitle: String {
        switch phase {
        case .checking, .ready: file.typeLabel
        case .failed(let failure): failure.message
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .checking:
            DelayedProgressView().controlSize(.small)
        case .ready:
            Button { Task { await save() } } label: {
                Label("Save", palIcon: "square.and.arrow.down")
            }
            .buttonStyle(PillButtonStyle(kind: .neutral))
            .disabled(isSaving)
            .accessibilityLabel(Text("Save \(file.name)"))
            .accessibilityIdentifier("chatFileSave")
        case .failed:
            if phase.offersRetry {
                Button { attempt += 1 } label: {
                    Label("Retry", palIcon: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                .accessibilityIdentifier("chatFileRetry")
            }
        }
    }

    private func check() async {
        guard !isStreaming, let actions else { return }
        phase = .checking
        do {
            for round in 0..<Self.probeAttempts {
                if try await actions.check(file) == .available {
                    phase = .ready
                    return
                }
                if round < Self.probeAttempts - 1 { try await Task.sleep(for: Self.probeDelay) }
            }
            phase = .failed(FileLoadFailure(cause: .notFound))
        } catch is CancellationError {
        } catch {
            phase = .failed(FileLoadFailure(describing: error))
        }
    }

    private func save() async {
        guard let actions, !isSaving else { return }
        isSaving = true
        notice = nil
        defer { isSaving = false }
        let data: Data
        do {
            data = try await actions.load(file)
        } catch is CancellationError {
            return
        } catch {
            notice = FileLoadFailure(describing: error).message
            return
        }
        do {
            let saved = try await FileSaver.save(data, name: file.name)
            notice = saved.isEmpty ? nil : saved
        } catch is CancellationError {
        } catch {
            notice = String(localized: "Couldn't save this file")
        }
    }
}
