import SwiftUI

enum PlatformVariant {
    static func pick<Value>(mac: @autoclosure () -> Value, iOS: @autoclosure () -> Value) -> Value {
        #if os(macOS)
        mac()
        #else
        iOS()
        #endif
    }
}

extension View {
    func macOnly(_ transform: (Self) -> some View) -> some View {
        #if os(macOS)
        transform(self)
        #else
        self
        #endif
    }

    func iOSOnly(_ transform: (Self) -> some View) -> some View {
        #if os(iOS)
        transform(self)
        #else
        self
        #endif
    }
}
