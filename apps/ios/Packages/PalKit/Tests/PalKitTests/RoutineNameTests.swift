import Foundation
import PalBotProfile
import Testing

@Suite("Routine names read as natural language")
struct RoutineNameTests {
    private func shown(_ stored: String, id: String = "abc123def456") -> String {
        Routine(id: id, title: stored, scheduleText: nil, timeZoneID: nil, isEnabled: true).title
    }

    @Test(arguments: [
        ("daily_report_job", "Daily report job"),
        ("weekly-news-digest", "Weekly news digest"),
        ("DAILY_REPORT", "Daily report"),
        ("  morning   brief  ", "Morning brief"),
        ("daily_report_3f9a2c1d", "Daily report"),
        ("Morning digest", "Morning digest"),
        ("Check Wi-Fi status", "Check Wi-Fi status"),
        ("iPhone backup", "iPhone backup"),
    ])
    func englishName(stored: String, expected: String) {
        #expect(shown(stored) == expected)
    }

    @Test(arguments: [
        ("tóm_tắt_tin_tức", "Tóm tắt tin tức"),
        ("đọc-email-buổi-sáng", "Đọc email buổi sáng"),
        ("ôn_tập".decomposedStringWithCanonicalMapping, "Ôn tập"),
        ("nhắc uống nước", "Nhắc uống nước"),
        ("Báo cáo buổi sáng", "Báo cáo buổi sáng"),
    ])
    func vietnameseName(stored: String, expected: String) {
        #expect(shown(stored) == expected)
    }

    @Test(arguments: [
        "", "   ", "---", "abc123def456", "3f9a2c1d4e5b6a7f", "20261127",
        "9b2d7c1e-4a53-4f0e-9c77-1a2b3c4d5e6f", "9B2D7C1E4A534F0E9C771A2B3C4D5E6F", "3f9a2c1d_4e5b6a7f",
    ])
    func idsAndHexStringsNeverShow(stored: String) {
        #expect(shown(stored) == "Untitled routine")
    }

    @Test func theJobIDNeverShowsAsAName() {
        #expect(shown("j1", id: "j1") == "Untitled routine")
    }

    @Test(arguments: ["daily_report_job", "tóm_tắt_tin_tức", "3f9a2c1d4e5b6a7f", "Check Wi-Fi status"])
    func aShownNameStaysAsItIs(stored: String) {
        #expect(shown(shown(stored)) == shown(stored))
    }

    @Test func aCachedRoutineIsReadTheSameWay() throws {
        let cached = Data(#"{"id":"abc123def456","title":"daily_report_job","isEnabled":true}"#.utf8)
        #expect(try JSONDecoder().decode(Routine.self, from: cached).title == "Daily report job")
    }
}
