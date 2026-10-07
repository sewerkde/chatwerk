import Foundation

/// Background full-text indexer. Transcripts are append-only JSONL, so each
/// session remembers the byte offset already indexed and only new bytes are
/// parsed on later runs. AppState runs at most one Indexer at a time — two
/// concurrent runs could both start from the same stale offset and index
/// (and bill) a chunk twice.
final class Indexer {
    let db: Database
    private let chunkSize = 4 * 1024 * 1024

    /// A transcript written to within this window may end in a half-written
    /// line; older files are taken as complete even without a final newline.
    private let activeWindow: TimeInterval = 120

    /// Called after each file finishes: (indexedFiles, totalFiles).
    var progress: ((Int, Int) -> Void)?

    init(db: Database) { self.db = db }

    func runOnce() {
        let backlog = db.sessionsNeedingIndexing()
        let subagents = db.subagentFilesNeedingIndexing()
        let total = backlog.count + subagents.count
        var done = 0
        for row in backlog {
            indexSession(row)
            done += 1
            progress?(done, total)
        }
        for row in subagents {
            indexSubagent(row)
            done += 1
            progress?(done, total)
        }
    }

    private func indexSession(_ row: Database.SessionRow) {
        var offset = UInt64(row.indexedOffset)
        var lastUsageMsgId = row.lastUsageMsgId

        // Truncated or rewritten file → start over.
        if row.size < row.indexedOffset {
            db.resetIndex(uuid: row.uuid, projectDir: row.projectDir)
            offset = 0
            lastUsageMsgId = nil
        }
        indexFile(path: row.path, uuid: row.uuid, projectDir: row.projectDir, source: .session,
                  offset: offset, lastUsageMsgId: lastUsageMsgId, modifiedAt: row.modifiedAt, searchable: true)
    }

    private func indexSubagent(_ row: Database.SubagentRow) {
        var offset = UInt64(row.indexedOffset)
        var lastUsageMsgId = row.lastUsageMsgId
        // A subagent transcript's share can't be unwound from the session
        // totals on its own, so a rewritten one restarts the whole session.
        if row.size < row.indexedOffset {
            db.resetIndex(uuid: row.uuid, projectDir: row.projectDir)
            offset = 0
            lastUsageMsgId = nil
        }
        indexFile(path: row.path, uuid: row.uuid, projectDir: row.projectDir, source: .subagent(path: row.path),
                  offset: offset, lastUsageMsgId: lastUsageMsgId, modifiedAt: row.modifiedAt, searchable: false)
    }

    private func indexFile(path: String, uuid: String, projectDir: String, source: Database.ChunkSource,
                           offset startOffset: UInt64, lastUsageMsgId: String?, modifiedAt: Double, searchable: Bool) {
        var offset = startOffset
        let active = Date().timeIntervalSince1970 - modifiedAt < activeWindow

        // Assistant messages can repeat across lines (one per content block,
        // all carrying the same usage); count usage once per id. Seed with
        // the last id counted by a previous run so a message whose lines
        // straddle two incremental passes isn't double-counted.
        var seenMessageIds = Set<String>()
        if let last = lastUsageMsgId { seenMessageIds.insert(last) }

        while true {
            guard let chunk = JSONL.readLines(path: path, offset: offset, length: chunkSize,
                                              holdTrailingFragment: active) else { break }

            var entries: [(role: String, text: String)] = []
            var added = 0
            var usage = Database.ChunkUsage()

            for line in chunk.lines {
                guard JSONL.lineHasPrefix(line, anyOf: ["{\"parentUuid\"", "{\"type\":\"user\"", "{\"type\":\"assistant\""]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
                guard let message = obj["message"] as? [String: Any] else { continue }

                // Token usage aggregation (assistant messages carry `usage`).
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
                            usage.byModel[model, default: .init()].add(bucket)
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

                // Only the main conversation is searchable: subagent
                // transcripts and sidechain lines stay out of the FTS index.
                guard searchable, (obj["isSidechain"] as? Bool) != true else { continue }
                guard let text = JSONL.messageText(message) else { continue }
                if type == "user", JSONL.isNoiseText(text) { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                entries.append((role: type, text: String(trimmed.prefix(100_000))))
                added += 1
            }

            if chunk.nextOffset > offset {
                db.commitChunk(uuid: uuid, projectDir: projectDir, source: source, entries: entries,
                               newOffset: Int64(chunk.nextOffset), addedMessages: added, usage: usage)
            }

            if chunk.atEOF || chunk.nextOffset <= offset { break }
            offset = chunk.nextOffset
        }
    }
}
