#if os(macOS)
import AppKit
import PalDiagnostics
import SwiftUI

extension View {
    @ViewBuilder
    func paneOverflowProbe(_ name: String) -> some View {
        if PaneOverflowProbe.isOn {
            background(PaneOverflowProbe(name: name))
        } else {
            self
        }
    }
}

private struct PaneOverflowProbe: NSViewRepresentable {
    static let isOn = PalPerf.isRequested()
    static let settleDelay = Duration.milliseconds(300)

    let name: String

    func makeNSView(context: Context) -> ProbeView { ProbeView(name: name) }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private let name: String
        private var observer: NSObjectProtocol?
        private var pending: Task<Void, Never>?

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObserver()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkWhenSettled() }
            }
            checkWhenSettled()
        }

        isolated deinit {
            removeObserver()
            pending?.cancel()
        }

        private func removeObserver() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func checkWhenSettled() {
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: PaneOverflowProbe.settleDelay)
                guard !Task.isCancelled else { return }
                self?.report()
            }
        }

        private func report() {
            guard let content = window?.contentView else { return }
            let frame = convert(bounds, to: nil)
            let contentFrame = content.convert(content.bounds, to: nil)
            let overflow = max(frame.maxX - contentFrame.maxX, contentFrame.minX - frame.minX)
            guard overflow > 1 else { return }
            PalPerf.event("layout.overflow", label: name, points: Int(overflow.rounded(.up)))
        }
    }
}
#else
import SwiftUI

extension View {
    func paneOverflowProbe(_ name: String) -> some View { self }
}
#endif
