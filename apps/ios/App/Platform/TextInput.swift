import SwiftUI

#if os(iOS)
import UIKit

typealias PlatformTextContentType = UITextContentType
#elseif os(macOS)
import AppKit

typealias PlatformTextContentType = NSTextContentType
#endif

extension View {
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        textContentType(.URL)
            .autocorrectionDisabled()
        #endif
    }

    func neverAutocapitalized() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    func autocapitalization(sentences: Bool) -> some View {
        #if os(iOS)
        textInputAutocapitalization(sentences ? .sentences : .never)
        #else
        self
        #endif
    }

    func clearNavigationBackground() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }
}
