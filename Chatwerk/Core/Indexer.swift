import Foundation

/// Background full-text indexer. Transcripts are append-only JSONL, so each
/// session remembers the byte offset already indexed and only new bytes are
/// parsed on later runs.
final class Indexer {
    let db: Database
    private let chunkSize = 4 * 1024 * 1024

    /// Called after each file finishes: (indexedFiles, totalFiles).
    var progress: ((Int, Int) -> Void)?
    private var cancelled = false

    init(db: Database) { self.db = db }

    func cancel() { cancelled = true }

    func runOnce() {
        cancelled = false
        let backlog = db.sessionsNeedingIndexing()
        let total = backlog.count
        for (i, row) in backlog.enumerated() {
            if cancelled { return }
            indexFile(row)
            progress?(i + 1, total)
        }
    }

    private func indexFile(_ row: Database.SessionRow) {
        var offset = UInt64(row.indexedOffset)

        // Truncated or rewritten file → start over.
        if row.size < row.indexedOffset {
            db.resetIndex(uuid: row.uuid, projectDir: row.projectDir)
            offset = 0
        }

        while true {
            if cancelled { return }
            guard let chunk = JSONL.readLines(path: row.path, offset: offset, length: chunkSize) else { break }

            var entries: [(role: String, text: String)] = []
            var added = 0
            for line in chunk.lines {
                guard JSONL.lineHasPrefix(line, anyOf: ["{\"parentUuid\"", "{\"type\":\"user\"", "{\"type\":\"assistant\""]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
                guard (obj["isSidechain"] as? Bool) != true else { continue }
                guard let message = obj["message"] as? [String: Any],
                      let text = JSONL.messageText(message) else { continue }
                if type == "user", JSONL.isNoiseText(text) { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                entries.append((role: type, text: String(trimmed.prefix(100_000))))
                added += 1
            }

            db.appendIndexed(uuid: row.uuid, projectDir: row.projectDir,
                             entries: entries, newOffset: Int64(chunk.nextOffset), addedMessages: added)

            if chunk.atEOF || chunk.nextOffset <= offset { break }
            offset = chunk.nextOffset
        }
    }
}
