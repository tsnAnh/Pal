import Foundation
import Testing

@Suite("Tool approval card policy")
struct ToolApprovalCardPolicyTests {
    private static let appRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    private static let removed = ["struct ApprovalCard", "struct ApprovalAnsweredCard", "enum ApprovalWording", "approvalChoice-"]

    @Test func theAllowDenyApprovalCardStaysGone() throws {
        let root = Self.appRoot
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for marker in Self.removed {
                #expect(!text.contains(marker), "\(url.lastPathComponent) brings back \(marker); owner decisions use the clarify form")
            }
        }
        #expect(scanned > 0)
    }
}
