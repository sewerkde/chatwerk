import Foundation

/// Background full-text indexer. Transcripts are append-only JSONL, so each
/// session remembers the byte offset already indexed and only new bytes are
/// parsed on later runs. AppState runs at most one Indexer at a time — two
/// concurrent runs could both start from the same stale offset and index
/// (and bill) a chunk twice.
final class Indexer {
    let db: Database
    private let chunkSize = 4 * 1024 * 1024

    /// Called after each file finishes: (indexedFiles, totalFiles).
    var progress: ((Int, Int) -> Void)?

    init(db: Database) { self.db = db }

    func runOnce() {
        let backlog = db.sessionsNeedingIndexing()
        let total = backlog.count
        for (i, row) in backlog.enumerated() {
            indexFile(row)
            progress?(i + 1, total)
        }
    }

    private func indexFile(_ row: Database.SessionRow) {
        var offset = UInt64(row.indexedOffset)
        var lastUsageMsgId = row.lastUsageMsgId

        // Truncated or rewritten file → start over.
        if row.size < row.indexedOffset {
            db.resetIndex(uuid: row.uuid, projectDir: row.projectDir)
            offset = 0
            lastUsageMsgId = nil
        }

        // Assistant messages can repeat across lines; count usage once per id.
        // Seed with the last id counted by a previous run so a message whose
        // lines straddle two incremental passes isn't double-counted.
        var seenMessageIds = Set<String>()
        if let last = lastUsageMsgId { seenMessageIds.insert(last) }

        while true {
            guard let chunk = JSONL.readLines(path: row.path, offset: offset, length: chunkSize) else { break }

            var entries: [(role: String, text: String)] = []
            var added = 0
            var usage = Database.ChunkUsage()

            for line in chunk.lines {
                guard JSONL.lineHasPrefix(line, anyOf: ["{\"parentUuid\"", "{\"type\":\"user\"", "{\"type\":\"assistant\""]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
                guard let message = obj["message"] as? [String: Any] else { continue }

                // Token usage aggregation (assistant messages carry `usage`).
                // Runs BEFORE the sidechain skip: subagent turns bill too.
                if type == "assistant",
                   let raw = message["usage"] as? [String: Any] {
                    let id = (message["id"] as? String) ?? UUID().uuidString
                    if !seenMessageIds.contains(id) {
                        seenMessageIds.insert(id)
                        let cacheWrite = (raw["cache_creation_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        // 1h-TTL cache writes bill at 2× vs 1.25× for 5m;
                        // the breakdown lives in usage.cache_creation.
                        let cacheWrite1h = ((raw["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value ?? 0
                        let bucket = Database.UsageBucket(
                            input: (raw["input_tokens"] as? NSNumber)?.int64Value ?? 0,
                            output: (raw["output_tokens"] as? NSNumber)?.int64Value ?? 0,
                            cacheRead: (raw["cache_read_input_tokens"] as? NSNumber)?.int64Value ?? 0,
                            cacheWrite: cacheWrite,
                            cacheWrite1h: min(cacheWrite1h, cacheWrite))
                        if bucket.total > 0 {
                            usage.session.add(bucket)
                            usage.lastMessageId = id
                            let model = (message["model"] as? String) ?? "unknown"
                            // A line without a usable timestamp still counts toward
                            // the session total, but can't go into a day/hour bucket
                            // (a placeholder key would sort after every real date).
                            if let ts = obj["timestamp"] as? String, ts.count >= 13, ts.first?.isNumber == true {
                                usage.daily[.init(period: String(ts.prefix(10)), model: model), default: .init()].add(bucket)
                                usage.hourly[.init(period: String(ts.prefix(13)), model: model), default: .init()].add(bucket)
                            }
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

            db.commitChunk(uuid: row.uuid, projectDir: row.projectDir, entries: entries,
                           newOffset: Int64(chunk.nextOffset), addedMessages: added, usage: usage)

            if chunk.atEOF || chunk.nextOffset <= offset { break }
            offset = chunk.nextOffset
        }
    }
}
