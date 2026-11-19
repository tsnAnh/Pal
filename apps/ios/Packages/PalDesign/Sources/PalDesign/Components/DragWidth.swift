import Foundation
import Observation

@MainActor
@Observable
public final class DragWidth {
    public let range: ClosedRange<Double>
    public private(set) var live: Double
    @ObservationIgnored private let persist: @MainActor (Double) -> Void
    @ObservationIgnored private var committed: Double
    @ObservationIgnored private var origin: Double?

    public init(stored: Double, range: ClosedRange<Double>, persist: @escaping @MainActor (Double) -> Void) {
        let start = Self.clamp(stored, to: range)
        self.range = range
        self.persist = persist
        live = start
        committed = start
    }

    public func drag(by translation: Double) {
        let start = origin ?? live
        origin = start
        let next = Self.clamp(start + translation, to: range)
        guard next != live else { return }
        live = next
    }

    public func endDrag() {
        guard origin != nil else { return }
        origin = nil
        guard live != committed else { return }
        committed = live
        persist(live)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
