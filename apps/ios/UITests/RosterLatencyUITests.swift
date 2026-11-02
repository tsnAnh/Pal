import XCTest

@MainActor
final class RosterLatencyUITests: E2ETestCase {
    private func value(_ element: XCUIElement) -> String? {
        element.value as? String
    }

    private func wait(for element: XCUIElement, toBe expected: String, timeout: TimeInterval, requireLabel: String? = nil) -> Date? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value(element) == expected, requireLabel.map({ element.label.contains($0) }) ?? true { return Date() }
        }
        return nil
    }

    private func externalTimestamp(_ file: String, key: String) -> Double? {
        guard let directory = env.shotsDirectory,
              let text = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object[key] as? Bool == true, let stamp = object["t"] as? Double else { continue }
            return stamp
        }
        return nil
    }

    func testExternalTurnRowLatency() throws {
        let app = launch(resetCredentials: true)
        signInIfNeeded(app)
        let alpha = app.buttons["botRow-bot-alpha"]
        waitFor(alpha, timeout: 30, "alpha row")
        XCTAssertNotNil(wait(for: alpha, toBe: "idle", timeout: 30), "alpha starts idle")

        try control("external-slow-alpha")
        let uiWorking = wait(for: alpha, toBe: "working", timeout: 20)
        let uiIdle = wait(for: alpha, toBe: "idle", timeout: 110, requireLabel: "slow-")

        var deadline = Date().addingTimeInterval(15)
        while externalTimestamp("external-complete.log", key: "completed") == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        deadline = Date()
        let admitted = externalTimestamp("external-client.log", key: "admitted")
        let completed = externalTimestamp("external-complete.log", key: "completed")
        func field(_ date: Date?) -> String { date.map { String(format: "%.4f", $0.timeIntervalSince1970) } ?? "" }
        func number(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "" }
        let line = "t_admit,t_ui_working,t_complete,t_ui_idle\n\(number(admitted)),\(field(uiWorking)),\(number(completed)),\(field(uiIdle))\n"
        if let directory = env.shotsDirectory {
            try line.write(toFile: directory + "/ui-latency.csv", atomically: true, encoding: .utf8)
        }
        shot(app, "roster-latency-final")
        try control("stop-external")
        XCTAssertNotNil(admitted, "external client admission timestamp recorded")
    }
}
