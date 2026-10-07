import Foundation
import Darwin

/// Reads ~/.claude/sessions/<pid>.json to find currently running Claude Code
/// processes, so live sessions get a badge and are protected from deletion.
enum LiveSessions {

    struct Live {
        var sessionId: String
        var pid: Int32
        var status: String?
        var cwd: String?
    }

    /// Claude Code writes `procStart` in ctime form ("Wed Oct  7 17:00:01 2026"),
    /// currently as UTC. The string carries no zone, so both readings are
    /// tried and the record counts as matching if either one does.
    private static let procStartFormatters: [DateFormatter] = {
        [TimeZone(identifier: "UTC") ?? .current, .current].map { zone in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            f.timeZone = zone
            return f
        }
    }()

    /// False when the record's start time matches neither reading of the
    /// process's real start time — the pid now belongs to something else.
    private static func recordMatchesProcess(_ obj: [String: Any], pid: Int32) -> Bool {
        guard let raw = obj["procStart"] as? String, let actual = processStart(pid: pid) else { return true }
        let text = raw.replacingOccurrences(of: "  ", with: " ")
        let readings = procStartFormatters.compactMap { $0.date(from: text) }
        guard !readings.isEmpty else { return true }
        return readings.contains { abs(actual.timeIntervalSince($0)) <= 5 }
    }

    static func current() -> [String: Live] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: ClaudePaths.liveSessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        // Oldest record first: when two records claim the same session (a
        // leftover file from an earlier process), the newest one wins
        // deterministically instead of whichever the directory listed last.
        let ordered = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }

        var out: [String: Live] = [:]
        for file in ordered {
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sessionId = obj["sessionId"] as? String,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value else { continue }
            // Stale record check: is the process still alive? EPERM means it
            // exists but belongs to another user (e.g. claude run via sudo).
            guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { continue }
            // A crashed Claude Code leaves its record behind; once the pid is
            // handed to an unrelated process the session would look live
            // forever. The record's own start time tells the two apart.
            guard recordMatchesProcess(obj, pid: pid) else { continue }
            out[sessionId] = Live(sessionId: sessionId, pid: pid,
                                  status: obj["status"] as? String,
                                  cwd: obj["cwd"] as? String)
        }
        return out
    }

    /// Kernel-reported start time of a process, nil when it can't be read.
    private static func processStart(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
