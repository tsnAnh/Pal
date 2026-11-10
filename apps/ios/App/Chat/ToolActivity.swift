import Foundation

enum ToolActivity {
    private static let exact: [String: String] = [
        "terminal": String(localized: "Running a command"),
        "process_manage": String(localized: "Managing a background task"),
        "execute_code": String(localized: "Running code"),
        "web_search": String(localized: "Searching the web"),
        "web_extract": String(localized: "Reading a web page"),
        "read_file": String(localized: "Reading files"),
        "write_file": String(localized: "Writing a file"),
        "patch": String(localized: "Editing a file"),
        "search_files": String(localized: "Searching files"),
        "vision_analyze": String(localized: "Looking at an image"),
        "image_generate": String(localized: "Creating an image"),
        "text_to_speech": String(localized: "Preparing audio"),
        "skills_list": String(localized: "Checking skills"),
        "skill_view": String(localized: "Checking skills"),
        "skill_manage": String(localized: "Updating skills"),
        "todo_list": String(localized: "Planning the steps"),
        "memory": String(localized: "Updating memory"),
        "session_search": String(localized: "Looking through past chats"),
        "delegate_task": String(localized: "Working with a helper"),
        "cronjob_manage": String(localized: "Setting up a routine"),
        "computer_use": String(localized: "Using the computer"),
        "message_agent": String(localized: "Asking another Bot"),
        "iphone": String(localized: "Checking your iPhone"),
    ]

    static func label(for toolName: String) -> String {
        if let known = exact[toolName] { return known }
        if toolName.hasPrefix("browser") { return String(localized: "Browsing the web") }
        if toolName.hasPrefix("kanban") { return String(localized: "Updating the task board") }
        return String(localized: "Working on it")
    }
}
