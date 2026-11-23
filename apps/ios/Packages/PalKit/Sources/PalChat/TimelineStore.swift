import Foundation

public protocol TimelineStore: Sendable {
    func load() async -> CachedTimeline?
    func save(_ timeline: CachedTimeline)
}
