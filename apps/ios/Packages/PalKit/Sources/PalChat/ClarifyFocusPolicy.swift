import Foundation

public enum ClarifyFocusPolicy {
    public static func claimsFocus(composerFocused: Bool, draft: String) -> Bool {
        !composerFocused && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
