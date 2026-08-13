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

        // Assistant messages can repeat across lines; count usage once per id.
        var seenMessageIds = Set<String>()

        while true {
            if cancelled { return }
            guard let chunk = JSONL.readLines(path: row.path, offset: offset, length: chunkSize) else { break }

            var entries: [(role: String, text: String)] = []
            var added = 0
            var totIn: Int64 = 0, totOut: Int64 = 0, totCR: Int64 = 0, totCW: Int64 = 0
            var daily: [String: (input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64)] = [:]

            for line in chunk.lines {
                guard JSONL.lineHasPrefix(line, anyOf: ["{\"parentUuid\"", "{\"type\":\"user\"", "{\"type\":\"assistant\""]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
                guard (obj["isSidechain"] as? Bool) != true else { continue }
                guard let message = obj["message"] as? [String: Any] else { continue }

                // Token usage aggregation (assistant messages carry `usage`).
                if type == "assistant",
                   let usage = message["usage"] as? [String: Any] {
                    let id = (message["id"] as? String) ?? UUID().uuidString
                    if !seenMessageIds.contains(id) {
                        seenMessageIds.insert(id)
                        let inTok = (usage["input_tokens"] as? NSNumber)?.int64Value ?? 0
                        let outTok = (usage["output_tokens"] as? NSNumber)?.int64Value ?? 0
                        let crTok = (usage["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        let cwTok = (usage["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        if inTok + outTok + crTok + cwTok > 0 {
                            totIn += inTok; totOut += outTok; totCR += crTok; totCW += cwTok
                            let model = (message["model"] as? String) ?? "unknown"
                            let day = String(((obj["timestamp"] as? String) ?? "unknown").prefix(10))
                            let key = day + "|" + model
                            var agg = daily[key] ?? (0, 0, 0, 0)
                            agg.input += inTok; agg.output += outTok
                            agg.cacheRead += crTok; agg.cacheWrite += cwTok
                            daily[key] = agg
                        }
                    }
                }

                guard let text = JSONL.messageText(message) else { continue }
                if type == "user", JSONL.isNoiseText(text) { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                entries.append((role: type, text: String(trimmed.prefix(100_000))))
                added += 1
            }

            db.appendIndexed(uuid: row.uuid, projectDir: row.projectDir,
                             entries: entries, newOffset: Int64(chunk.nextOffset), addedMessages: added)
            db.recordUsage(uuid: row.uuid, projectDir: row.projectDir,
                           input: totIn, output: totOut, cacheRead: totCR, cacheWrite: totCW,
                           daily: daily.map { key, agg in
                               let parts = key.split(separator: "|", maxSplits: 1)
                               return (day: String(parts[0]),
                                       model: parts.count > 1 ? String(parts[1]) : "unknown",
                                       input: agg.input, output: agg.output,
                                       cacheRead: agg.cacheRead, cacheWrite: agg.cacheWrite)
                           })

            if chunk.atEOF || chunk.nextOffset <= offset { break }
            offset = chunk.nextOffset
        }
    }
}
