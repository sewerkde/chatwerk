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
        // Seed with the last id counted by a previous run so a message whose
        // lines straddle two incremental passes isn't double-counted.
        var seenMessageIds = Set<String>()
        if let last = row.lastUsageMsgId { seenMessageIds.insert(last) }
        var lastCountedId: String?

        while true {
            if cancelled { return }
            guard let chunk = JSONL.readLines(path: row.path, offset: offset, length: chunkSize) else { break }

            var entries: [(role: String, text: String)] = []
            var added = 0
            var totIn: Int64 = 0, totOut: Int64 = 0, totCR: Int64 = 0, totCW: Int64 = 0, totCW1h: Int64 = 0
            var daily: [String: (input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cacheWrite1h: Int64)] = [:]
            var hourly: [String: (input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cacheWrite1h: Int64)] = [:]

            for line in chunk.lines {
                guard JSONL.lineHasPrefix(line, anyOf: ["{\"parentUuid\"", "{\"type\":\"user\"", "{\"type\":\"assistant\""]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
                guard let message = obj["message"] as? [String: Any] else { continue }

                // Token usage aggregation (assistant messages carry `usage`).
                // Runs BEFORE the sidechain skip: subagent turns bill too.
                if type == "assistant",
                   let usage = message["usage"] as? [String: Any] {
                    let id = (message["id"] as? String) ?? UUID().uuidString
                    if !seenMessageIds.contains(id) {
                        seenMessageIds.insert(id)
                        let inTok = (usage["input_tokens"] as? NSNumber)?.int64Value ?? 0
                        let outTok = (usage["output_tokens"] as? NSNumber)?.int64Value ?? 0
                        let crTok = (usage["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        let cwTok = (usage["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        // 1h-TTL cache writes bill at 2× vs 1.25× for 5m;
                        // the breakdown lives in usage.cache_creation.
                        let cw1hTok = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        if inTok + outTok + crTok + cwTok > 0 {
                            totIn += inTok; totOut += outTok; totCR += crTok; totCW += cwTok
                            totCW1h += min(cw1hTok, cwTok)
                            lastCountedId = id
                            let model = (message["model"] as? String) ?? "unknown"
                            let timestamp = (obj["timestamp"] as? String) ?? "unknown"
                            let key = String(timestamp.prefix(10)) + "|" + model
                            var agg = daily[key] ?? (0, 0, 0, 0, 0)
                            agg.input += inTok; agg.output += outTok
                            agg.cacheRead += crTok; agg.cacheWrite += cwTok
                            agg.cacheWrite1h += min(cw1hTok, cwTok)
                            daily[key] = agg
                            let hourKey = String(timestamp.prefix(13)) + "|" + model
                            var hagg = hourly[hourKey] ?? (0, 0, 0, 0, 0)
                            hagg.input += inTok; hagg.output += outTok
                            hagg.cacheRead += crTok; hagg.cacheWrite += cwTok
                            hagg.cacheWrite1h += min(cw1hTok, cwTok)
                            hourly[hourKey] = hagg
                        }
                    }
                }

                // Sidechain (subagent) text stays out of the FTS index —
                // only the main conversation should be searchable.
                guard (obj["isSidechain"] as? Bool) != true else { continue }
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
                           cacheWrite1h: totCW1h, lastMessageId: lastCountedId,
                           daily: daily.map { key, agg in
                               let parts = key.split(separator: "|", maxSplits: 1)
                               return (day: String(parts[0]),
                                       model: parts.count > 1 ? String(parts[1]) : "unknown",
                                       input: agg.input, output: agg.output,
                                       cacheRead: agg.cacheRead, cacheWrite: agg.cacheWrite,
                                       cacheWrite1h: agg.cacheWrite1h)
                           },
                           hourly: hourly.map { key, agg in
                               let parts = key.split(separator: "|", maxSplits: 1)
                               return (hour: String(parts[0]),
                                       model: parts.count > 1 ? String(parts[1]) : "unknown",
                                       input: agg.input, output: agg.output,
                                       cacheRead: agg.cacheRead, cacheWrite: agg.cacheWrite,
                                       cacheWrite1h: agg.cacheWrite1h)
                           })

            if chunk.atEOF || chunk.nextOffset <= offset { break }
            offset = chunk.nextOffset
        }
    }
}
