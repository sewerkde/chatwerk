import Foundation

/// Reads ~/.claude/sessions/<pid>.json to find currently running Claude Code
/// processes, so live sessions get a badge and are protected from deletion.
enum LiveSessions {

    struct Live {
        var sessionId: String
        var pid: Int32
        var status: String?
        var cwd: String?
    }

    static func current() -> [String: Live] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: ClaudePaths.liveSessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var out: [String: Live] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value else { continue }
            // Stale record check: is the process still alive?
            guard kill(pid, 0) == 0 else { continue }
            out[sessionId] = Live(sessionId: sessionId, pid: pid,
                                  status: obj["status"] as? String,
                                  cwd: obj["cwd"] as? String)
        }
        return out
    }
}
