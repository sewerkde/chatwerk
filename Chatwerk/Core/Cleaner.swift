import Foundation

/// Archive (zip) and delete sessions. The ONLY place Chatwerk touches ~/.claude.
enum Cleaner {

    enum CleanError: LocalizedError {
        case sessionIsLive
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .sessionIsLive:
                return "This session is currently running in Claude Code. Close it before deleting."
            case .zipFailed(let msg):
                return "Archive failed: \(msg)"
            }
        }
    }

    /// Zip everything belonging to a session into `destinationDir`.
    static func archive(session: SessionInfo, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        let existing = ClaudePaths.sidecarPaths(projectDir: session.projectDir, uuid: session.uuid)
            .filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            throw CleanError.zipFailed("Nothing found on disk for this session.")
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let zipURL = destinationDir.appendingPathComponent("chatwerk-\(session.uuid.prefix(8))-\(stamp).zip")

        // Stage into a temp folder so one ditto call captures all pieces.
        let staging = fm.temporaryDirectory.appendingPathComponent("chatwerk-archive-\(UUID().uuidString)")
        let root = staging.appendingPathComponent(session.uuid)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for src in existing {
            let name = src.deletingLastPathComponent().lastPathComponent + "-" + src.lastPathComponent
            try fm.copyItem(at: src, to: root.appendingPathComponent(name))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", root.path, zipURL.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "?"
            throw CleanError.zipFailed(msg)
        }
        return zipURL
    }

    /// Permanently remove a session and its sidecars from disk.
    static func delete(session: SessionInfo, liveSessionIds: Set<String>) throws {
        guard !liveSessionIds.contains(session.uuid) else { throw CleanError.sessionIsLive }
        let fm = FileManager.default
        for url in ClaudePaths.sidecarPaths(projectDir: session.projectDir, uuid: session.uuid)
        where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// What would be removed (for the confirmation dialog).
    static func previewPaths(session: SessionInfo) -> [(path: String, size: Int64)] {
        let fm = FileManager.default
        return ClaudePaths.sidecarPaths(projectDir: session.projectDir, uuid: session.uuid)
            .filter { fm.fileExists(atPath: $0.path) }
            .map { ($0.path, directorySize($0)) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}
