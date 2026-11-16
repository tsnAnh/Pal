import PalChat
import PalDesign
import QuickLook
import SwiftUI

struct FilePreviewSheet: View {
    let file: FileReference

    private enum Phase {
        case loading
        case preview(URL)
        case saveOnly(URL, size: Int)
        case failed(String)
    }

    @Environment(\.chatFileActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme
    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var folder: URL?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(theme.palette.canvas))
                .navigationTitle(file.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() } label: { Text("Close") }
                            .accessibilityIdentifier("filePreviewClose")
                    }
                }
                .iOSOnly { $0.toolbarTitleDisplayMode(.inline) }
        }
        .macSheetFrame()
        .task(id: attempt) { await load() }
        .onDisappear(perform: removeTemporaryCopy)
        .accessibilityIdentifier("filePreview")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            DelayedProgressView()
                .accessibilityIdentifier("filePreviewLoading")
        case .preview(let url):
            QuickLookView(url: url)
                .accessibilityIdentifier("filePreviewContent")
        case .saveOnly(let url, let size):
            VStack(spacing: 12) {
                Image(systemName: "doc").font(.system(size: 44))
                Text(file.name).font(.headline).multilineTextAlignment(.center)
                Text("\(file.typeLabel) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                    .hermesText(.timestamp)
                Text("This file type can't be previewed.").hermesText(.timestamp)
                saveAction(url)
                if let notice { Text(notice).hermesText(.timestamp) }
            }
            .foregroundStyle(Color(theme.palette.textSecondary))
            .padding()
            .accessibilityIdentifier("filePreviewFallback")
        case .failed(let message):
            Button { attempt += 1 } label: {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.ellipsis").font(.system(size: 32))
                    Text(message).multilineTextAlignment(.center)
                    Text("Retry")
                }
                .foregroundStyle(Color(theme.palette.textSecondary))
                .padding()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filePreviewFailed")
        }
    }

    @ViewBuilder
    private func saveAction(_ url: URL) -> some View {
        #if os(macOS)
        Button {
            notice = (try? FileSaver.save(Data(contentsOf: url), name: file.name)) ?? String(localized: "The file could not be saved.")
        } label: {
            Label("Save as…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(PillButtonStyle(kind: .neutral))
        .accessibilityIdentifier("filePreviewSave")
        #else
        ShareLink(item: url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(PillButtonStyle(kind: .neutral))
        .accessibilityIdentifier("filePreviewShare")
        #endif
    }

    private func load() async {
        removeTemporaryCopy()
        guard let actions else {
            phase = .failed(String(localized: "Files aren't available here."))
            return
        }
        phase = .loading
        do {
            let data = try await actions.load(file)
            let url = try Self.write(data, name: file.name)
            folder = url.deletingLastPathComponent()
            phase = FilePreviewKind(fileName: file.name) == .quickLook ? .preview(url) : .saveOnly(url, size: data.count)
        } catch is CancellationError {
        } catch {
            phase = .failed(ImageLoadFailure(describing: error).reason)
        }
    }

    private func removeTemporaryCopy() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        self.folder = nil
    }

    private static func write(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: FileSaver.safeName(name), directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }
}

#if os(iOS)
private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    @MainActor
    final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#else
import QuickLookUI

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
#endif
