import Foundation

/// Discovers sessions with a cheap stat pass, then fills in titles/cwd for
/// changed files by reading only a head and a tail chunk of each transcript.
struct SessionScanner {
    let db: Database

    private static let chunkSize = 512 * 1024

    /// Stat every top-level `<uuid>.jsonl` under ~/.claude/projects/<dir>/.
    /// Returns the number of files seen.
    @discardableResult
    func statScan() -> Int {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var allPaths: [String] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let projectDir = dir.lastPathComponent
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let uuid = file.deletingPathExtension().lastPathComponent
                guard let rv = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else { continue }
                let size = Int64(rv.fileSize ?? 0)
                let mtime = rv.contentModificationDate?.timeIntervalSince1970 ?? 0
                let btime = rv.creationDate?.timeIntervalSince1970
                allPaths.append(file.path)
                db.upsertSessionStat(uuid: uuid, projectDir: projectDir, path: file.path,
                                     size: size, modifiedAt: mtime, createdAt: btime)
            }
        }
        db.deleteSessionsNotIn(paths: allPaths)
        return allPaths.count
    }

    /// Head/tail parse for every row whose file changed since last parse.
    func refreshDetails() {
        for row in db.sessionsNeedingDetails() {
            let d = Self.extractDetails(path: row.path)
            db.updateSessionDetails(
                uuid: row.uuid, projectDir: row.projectDir,
                cwd: d.cwd, title: d.title, firstPrompt: d.firstPrompt, lastPrompt: d.lastPrompt,
                gitBranch: d.gitBranch, model: d.model, detailMtime: row.modifiedAt)
        }
    }

    struct Details {
        var cwd: String?
        var title: String?
        var firstPrompt: String?
        var lastPrompt: String?
        var gitBranch: String?
        var model: String?
    }

    static func extractDetails(path: String) -> Details {
        var d = Details()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0

        // Head: first cwd/gitBranch + first human prompt.
        if let head = JSONL.readLines(path: path, offset: 0, length: chunkSize) {
            for line in head.lines {
                guard let obj = JSONL.parseLine(line) else { continue }
                if d.cwd == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    d.cwd = cwd
                    d.gitBranch = obj["gitBranch"] as? String
                }
                if d.firstPrompt == nil,
                   (obj["type"] as? String) == "user",
                   (obj["isSidechain"] as? Bool) != true,
                   (obj["isMeta"] as? Bool) != true,
                   let message = obj["message"] as? [String: Any],
                   let text = JSONL.messageText(message),
                   !JSONL.isNoiseText(text) {
                    d.firstPrompt = JSONL.cleanPrompt(text)
                }
                if d.cwd != nil, d.firstPrompt != nil { break }
            }
        }

        // Tail: last ai-title / last-prompt / model win.
        let tailOffset = size > Int64(chunkSize) ? UInt64(size - Int64(chunkSize)) : 0
        if let tail = JSONL.readLines(path: path, offset: tailOffset, length: chunkSize + 1024,
                                      dropFirstPartial: tailOffset > 0) {
            for line in tail.lines {
                guard JSONL.lineHasPrefix(line, anyOf: [
                    "{\"type\":\"ai-title\"", "{\"type\":\"last-prompt\"", "{\"parentUuid\"", "{\"type\":\"assistant\""
                ]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                switch obj["type"] as? String {
                case "ai-title":
                    if let t = obj["aiTitle"] as? String, !t.isEmpty { d.title = t }
                case "last-prompt":
                    if let p = obj["lastPrompt"] as? String, !p.isEmpty {
                        d.lastPrompt = JSONL.cleanPrompt(p)
                    }
                case "assistant":
                    if let message = obj["message"] as? [String: Any],
                       let model = message["model"] as? String {
                        d.model = model
                    }
                    if d.cwd == nil, let cwd = obj["cwd"] as? String { d.cwd = cwd }
                case "user":
                    if d.cwd == nil, let cwd = obj["cwd"] as? String { d.cwd = cwd }
                default:
                    break
                }
            }
        }

        if d.title == nil { d.title = d.firstPrompt.map { JSONL.cleanPrompt($0, maxLength: 100) } }
        return d
    }
}
