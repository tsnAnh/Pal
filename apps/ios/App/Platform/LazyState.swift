import Observation
import SwiftUI

@MainActor
@propertyWrapper
struct LazyState<Value: AnyObject & Observable>: DynamicProperty {
    @State private var holder = Holder()
    private let make: @MainActor () -> Value

    init(_ make: @escaping @MainActor () -> Value) {
        self.make = make
    }

    var wrappedValue: Value {
        if let value = holder.value { return value }
        let value = make()
        holder.value = value
        return value
    }

    var projectedValue: Bindable<Value> { Bindable(wrappedValue) }

    private final class Holder {
        var value: Value?
    }
}

struct ModelHost<Model: AnyObject & Observable, Content: View>: View {
    @LazyState private var model: Model
    private let content: (Model) -> Content

    init(_ make: @escaping @MainActor () -> Model, @ViewBuilder content: @escaping (Model) -> Content) {
        _model = LazyState(make)
        self.content = content
    }

    var body: some View {
        content(model)
    }
}
