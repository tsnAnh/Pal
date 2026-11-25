import SwiftUI

extension Binding {
    init(retaining source: Binding<Value?>, fallback: Value) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { newValue in
                if source.wrappedValue != nil { source.wrappedValue = newValue }
            }
        )
    }
}
