#if os(macOS)
import CoreFoundation
import Foundation

final class MainStallProbe: @unchecked Sendable {
    struct Stall: Codable, Equatable {
        let label: String
        let ms: Double
    }

    private(set) var longest = Stall(label: "none", ms: 0)
    private(set) var iterations = 0
    private var iterationStart: CFAbsoluteTime?
    private var observer: CFRunLoopObserver?

    func start() {
        let activities: CFRunLoopActivity = [.entry, .afterWaiting, .beforeWaiting, .exit]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.max) { [weak self] _, activity in
            self?.note(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    func measure(_ label: String, _ work: () -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        work()
        record(label, since: start)
    }

    private func note(_ activity: CFRunLoopActivity) {
        switch activity {
        case .entry, .afterWaiting:
            iterationStart = CFAbsoluteTimeGetCurrent()
        case .beforeWaiting, .exit:
            guard let start = iterationStart else { return }
            iterationStart = nil
            iterations += 1
            record("run loop turn \(iterations)", since: start)
        default:
            break
        }
    }

    private func record(_ label: String, since start: CFAbsoluteTime) {
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if ms > longest.ms { longest = Stall(label: label, ms: ms) }
    }
}
#endif
