import PalDiagnostics

extension ChatSession {
    func timed<Result>(_ name: StaticString, _ body: () async throws -> Result) async rethrows -> Result {
        let interval = PalPerf.begin(name)
        defer { interval.end() }
        return try await body()
    }
}
