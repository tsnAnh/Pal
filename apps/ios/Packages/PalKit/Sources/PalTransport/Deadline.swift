import Foundation

public struct SetupLimits: Sendable, Equatable {
    public var call: Duration
    public var step: Duration

    public init(call: Duration = .seconds(30), step: Duration = .seconds(120)) {
        self.call = call
        self.step = step
    }
}

public struct DeadlineExceeded: Error, Sendable, Equatable {
    public init() {}
}

public enum Deadline {
    public static func run<Value: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let (outcomes, sink) = AsyncStream<Result<Value, any Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            do { sink.yield(.success(try await operation())) } catch { sink.yield(.failure(error)) }
        }
        let timer = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            sink.yield(.failure(DeadlineExceeded()))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        var iterator = outcomes.makeAsyncIterator()
        guard let first = await iterator.next() else { throw CancellationError() }
        return try first.get()
    }
}
