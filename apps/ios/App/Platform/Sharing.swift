import SwiftUI

extension View {
    func shareSheet(isPresented: Binding<Bool>, items: @escaping @MainActor () -> [Any]) -> some View {
        #if os(iOS)
        sheet(isPresented: isPresented) {
            ActivityView(items: items())
                .presentationDetents([.medium, .large])
        }
        #else
        onChange(of: isPresented.wrappedValue) { _, presented in
            guard presented else { return }
            isPresented.wrappedValue = false
            SharePresenter.present(items: items())
        }
        #endif
    }
}

#if os(iOS)
import UIKit

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

@MainActor
enum SharePresenter {
    static func present(items: [Any], onFinish: @escaping @MainActor @Sendable () -> Void = {}) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        guard let top = topViewController() else {
            onFinish()
            return
        }
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.maxX - 44, y: top.view.safeAreaInsets.top + 22, width: 1, height: 1)
        top.present(controller, animated: true)
    }

    static func alert(title: String, message: String) {
        guard let top = topViewController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        top.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = active?.keyWindow?.rootViewController ?? active?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#elseif os(macOS)
import AppKit

@MainActor
enum SharePresenter {
    private static var active: PickerDelegate?

    static func present(items: [Any], onFinish: @escaping @MainActor @Sendable () -> Void = {}) {
        guard let view = NSApplication.shared.keyWindow?.contentView ?? NSApplication.shared.mainWindow?.contentView else {
            onFinish()
            return
        }
        let delegate = PickerDelegate {
            Task { @MainActor in
                active = nil
                onFinish()
            }
        }
        active = delegate
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = delegate
        let anchor = NSRect(x: view.bounds.maxX - 44, y: view.bounds.maxY - 22, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private final class PickerDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let finish: @Sendable () -> Void

        init(finish: @escaping @Sendable () -> Void) {
            self.finish = finish
        }

        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            guard let service else {
                finish()
                return
            }
            service.delegate = self
        }

        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
            finish()
        }

        func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finish()
        }
    }
}
#endif
