import Foundation

/// Well-known locations inside ~/.claude. Everything Chatwerk reads lives here;
/// Chatwerk never writes into this tree except for explicit delete/archive actions.
enum ClaudePaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Default ~/.claude, overridable in Settings for CLAUDE_CONFIG_DIR users.
    /// Resolved once per launch: the scanner, indexer and usage tables all
    /// assume one data folder for the lifetime of the process, so a change in
    /// Settings takes effect on the next start (as the Settings caption says).
    static let claudeDir: URL = {
        if let custom = UserDefaults.standard.string(forKey: "claudeDataDir"),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude")
    }()
    static var projectsDir: URL { claudeDir.appendingPathComponent("projects") }
    static var liveSessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    static var fileHistoryDir: URL { claudeDir.appendingPathComponent("file-history") }
    static var tasksDir: URL { claudeDir.appendingPathComponent("tasks") }
    static var sessionEnvDir: URL { claudeDir.appendingPathComponent("session-env") }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: projectsDir.path)
    }

    /// Everything on disk that belongs to one session (for delete/archive).
    static func sidecarPaths(projectDir: String, uuid: String) -> [URL] {
        let proj = projectsDir.appendingPathComponent(projectDir)
        return [
            proj.appendingPathComponent("\(uuid).jsonl"),
            proj.appendingPathComponent(uuid),                 // subagents/, tool-results/, workflows/
            fileHistoryDir.appendingPathComponent(uuid),
            tasksDir.appendingPathComponent(uuid),
            sessionEnvDir.appendingPathComponent(uuid),
        ]
    }

    /// Session ids are file names that end up inside a shell command; only
    /// the characters a Claude Code uuid can contain are accepted.
    static func isSessionId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Chatwerk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var databaseURL: URL { appSupportDir.appendingPathComponent("index.db") }
}
