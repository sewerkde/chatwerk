import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, serial-queue-guarded SQLite wrapper. All Chatwerk state (index cache,
/// full-text index, user notes/tags) lives in one file under Application Support.
final class Database {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "de.sewerk.chatwerk.db")

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            throw DBError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try queue.sync { try migrate() }
    }

    deinit { sqlite3_close_v2(db) }

    enum DBError: Error {
        case open(String)
        case exec(String)
    }

    // MARK: - Schema

    private func migrate() throws {
        try execRaw("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY,
            uuid TEXT NOT NULL,
            project_dir TEXT NOT NULL,
            path TEXT NOT NULL,
            cwd TEXT,
            title TEXT,
            first_prompt TEXT,
            last_prompt TEXT,
            git_branch TEXT,
            model TEXT,
            message_count INTEGER NOT NULL DEFAULT 0,
            size INTEGER NOT NULL DEFAULT 0,
            created_at REAL,
            modified_at REAL NOT NULL DEFAULT 0,
            detail_mtime REAL NOT NULL DEFAULT 0,
            indexed_offset INTEGER NOT NULL DEFAULT 0,
            UNIQUE(uuid, project_dir)
        );
        CREATE TABLE IF NOT EXISTS meta (
            uuid TEXT PRIMARY KEY,
            custom_title TEXT,
            note TEXT,
            favorite INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            color TEXT NOT NULL DEFAULT '#7B61FF'
        );
        CREATE TABLE IF NOT EXISTS session_tags (
            uuid TEXT NOT NULL,
            tag_id INTEGER NOT NULL,
            UNIQUE(uuid, tag_id)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
            uuid UNINDEXED, role UNINDEXED, content, tokenize='unicode61'
        );
        CREATE TABLE IF NOT EXISTS usage_daily (
            day TEXT NOT NULL,
            model TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            cache_write INTEGER NOT NULL DEFAULT 0,
            cache_write_1h INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, model)
        );
        """)

        // Additive columns for per-session token totals (ignore "already exists").
        for column in ["in_tokens", "out_tokens", "cache_read_tokens", "cache_write_tokens", "cache_write_1h_tokens"] {
            try? execRaw("ALTER TABLE sessions ADD COLUMN \(column) INTEGER NOT NULL DEFAULT 0")
        }
        try? execRaw("ALTER TABLE usage_daily ADD COLUMN cache_write_1h INTEGER NOT NULL DEFAULT 0")
        try? execRaw("ALTER TABLE sessions ADD COLUMN last_usage_msg_id TEXT")

        // Schema v4: usage aggregation with the 5m/1h cache-write split (they
        // bill differently) and subagent (sidechain) usage counted in; force
        // one full re-index so token data is backfilled from all transcripts.
        var version: Int32 = 0
        run("PRAGMA user_version") { s in version = sqlite3_column_int(s, 0) }
        if version < 4 {
            try execRaw("""
            DELETE FROM fts;
            DELETE FROM usage_daily;
            UPDATE sessions SET indexed_offset=0, message_count=0, last_usage_msg_id=NULL,
                in_tokens=0, out_tokens=0, cache_read_tokens=0, cache_write_tokens=0,
                cache_write_1h_tokens=0;
            PRAGMA user_version = 4;
            """)
        }
    }

    private func execRaw(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.exec(msg)
        }
    }

    // MARK: - Statement helper

    @discardableResult
    private func run(_ sql: String, _ params: [Any?] = [], row: (((OpaquePointer) -> Void))? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Chatwerk SQL prepare failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let row, let s = stmt { row(s) }
                continue
            }
            if rc == SQLITE_DONE { return true }
            NSLog("Chatwerk SQL step failed: %@ — %@", sql, String(cString: sqlite3_errmsg(db)))
            return false
        }
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }

    /// Runs `body` inside BEGIN…COMMIT; if any statement failed, the batch is
    /// rolled back instead of half-committed. Call only on `queue`.
    private func transaction(_ body: () -> Bool) {
        run("BEGIN")
        if body() {
            run("COMMIT")
        } else {
            run("ROLLBACK")
        }
    }

    // MARK: - Sessions

    struct SessionRow {
        var uuid: String
        var projectDir: String
        var path: String
        var size: Int64
        var modifiedAt: Double
        var createdAt: Double?
        var detailMtime: Double
        var indexedOffset: Int64
        var lastUsageMsgId: String?
    }

    func upsertSessionStat(uuid: String, projectDir: String, path: String,
                           size: Int64, modifiedAt: Double, createdAt: Double?) {
        queue.sync {
            _ = run("""
            INSERT INTO sessions (uuid, project_dir, path, size, modified_at, created_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(uuid, project_dir) DO UPDATE SET
                path=excluded.path, size=excluded.size,
                modified_at=excluded.modified_at, created_at=excluded.created_at
            """, [uuid, projectDir, path, size, modifiedAt, createdAt])
        }
    }

    func updateSessionDetails(uuid: String, projectDir: String, cwd: String?, title: String?,
                              firstPrompt: String?, lastPrompt: String?, gitBranch: String?,
                              model: String?, detailMtime: Double) {
        queue.sync {
            _ = run("""
            UPDATE sessions SET cwd=?, title=?, first_prompt=?, last_prompt=?,
                git_branch=COALESCE(?, git_branch), model=COALESCE(?, model), detail_mtime=?
            WHERE uuid=? AND project_dir=?
            """, [cwd, title, firstPrompt, lastPrompt, gitBranch, model, detailMtime, uuid, projectDir])
        }
    }

    func deleteSessionsNotIn(paths: [String]) {
        queue.sync {
            let existing = Set(paths)
            var stale: [(String, String)] = []
            run("SELECT uuid, project_dir, path FROM sessions") { s in
                let path = Database.text(s, 2) ?? ""
                if !existing.contains(path) {
                    stale.append((Database.text(s, 0) ?? "", Database.text(s, 1) ?? ""))
                }
            }
            for (uuid, dir) in stale {
                run("DELETE FROM sessions WHERE uuid=? AND project_dir=?", [uuid, dir])
                var remaining = 0
                run("SELECT COUNT(*) FROM sessions WHERE uuid=?", [uuid]) { s in
                    remaining = Int(sqlite3_column_int64(s, 0))
                }
                if remaining == 0 {
                    run("DELETE FROM fts WHERE uuid=?", [uuid])
                }
            }
        }
    }

    /// Rows whose file changed since the last head/tail detail parse.
    func sessionsNeedingDetails() -> [SessionRow] {
        queue.sync {
            var out: [SessionRow] = []
            run("SELECT uuid, project_dir, path, size, modified_at, created_at, detail_mtime, indexed_offset, last_usage_msg_id FROM sessions WHERE modified_at > detail_mtime") { s in
                out.append(SessionRow(
                    uuid: Database.text(s, 0) ?? "",
                    projectDir: Database.text(s, 1) ?? "",
                    path: Database.text(s, 2) ?? "",
                    size: sqlite3_column_int64(s, 3),
                    modifiedAt: sqlite3_column_double(s, 4),
                    createdAt: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : sqlite3_column_double(s, 5),
                    detailMtime: sqlite3_column_double(s, 6),
                    indexedOffset: sqlite3_column_int64(s, 7),
                    lastUsageMsgId: Database.text(s, 8)))
            }
            return out
        }
    }

    /// Rows with un-indexed bytes (size > indexed_offset), largest backlog first is NOT wanted —
    /// newest activity first so recent chats become searchable immediately.
    func sessionsNeedingIndexing() -> [SessionRow] {
        queue.sync {
            var out: [SessionRow] = []
            run("SELECT uuid, project_dir, path, size, modified_at, created_at, detail_mtime, indexed_offset, last_usage_msg_id FROM sessions WHERE size > indexed_offset ORDER BY modified_at DESC") { s in
                out.append(SessionRow(
                    uuid: Database.text(s, 0) ?? "",
                    projectDir: Database.text(s, 1) ?? "",
                    path: Database.text(s, 2) ?? "",
                    size: sqlite3_column_int64(s, 3),
                    modifiedAt: sqlite3_column_double(s, 4),
                    createdAt: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : sqlite3_column_double(s, 5),
                    detailMtime: sqlite3_column_double(s, 6),
                    indexedOffset: sqlite3_column_int64(s, 7),
                    lastUsageMsgId: Database.text(s, 8)))
            }
            return out
        }
    }

    func resetIndex(uuid: String, projectDir: String) {
        queue.sync {
            run("DELETE FROM fts WHERE uuid=?", [uuid])
            run("UPDATE sessions SET indexed_offset=0, message_count=0 WHERE uuid=? AND project_dir=?", [uuid, projectDir])
        }
    }

    func appendIndexed(uuid: String, projectDir: String, entries: [(role: String, text: String)],
                       newOffset: Int64, addedMessages: Int) {
        queue.sync {
            transaction {
                var ok = true
                for e in entries {
                    ok = run("INSERT INTO fts (uuid, role, content) VALUES (?,?,?)", [uuid, e.role, e.text]) && ok
                }
                ok = run("UPDATE sessions SET indexed_offset=?, message_count=message_count+? WHERE uuid=? AND project_dir=?",
                         [newOffset, addedMessages, uuid, projectDir]) && ok
                return ok
            }
        }
    }

    // MARK: - Usage aggregation

    struct UsageRow {
        var day: String
        var model: String
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        var cacheWrite1h: Int64
    }

    func recordUsage(uuid: String, projectDir: String,
                     input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cacheWrite1h: Int64,
                     lastMessageId: String?,
                     daily: [(day: String, model: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cacheWrite1h: Int64)]) {
        guard input + output + cacheRead + cacheWrite > 0 else { return }
        queue.sync {
            transaction {
                var ok = run("""
                UPDATE sessions SET in_tokens=in_tokens+?, out_tokens=out_tokens+?,
                    cache_read_tokens=cache_read_tokens+?, cache_write_tokens=cache_write_tokens+?,
                    cache_write_1h_tokens=cache_write_1h_tokens+?,
                    last_usage_msg_id=COALESCE(?, last_usage_msg_id)
                WHERE uuid=? AND project_dir=?
                """, [input, output, cacheRead, cacheWrite, cacheWrite1h, lastMessageId, uuid, projectDir])
                for d in daily {
                    ok = run("""
                    INSERT INTO usage_daily (day, model, input, output, cache_read, cache_write, cache_write_1h)
                    VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(day, model) DO UPDATE SET
                        input=input+excluded.input, output=output+excluded.output,
                        cache_read=cache_read+excluded.cache_read, cache_write=cache_write+excluded.cache_write,
                        cache_write_1h=cache_write_1h+excluded.cache_write_1h
                    """, [d.day, d.model, d.input, d.output, d.cacheRead, d.cacheWrite, d.cacheWrite1h]) && ok
                }
                return ok
            }
        }
    }

    func usageRows() -> [UsageRow] {
        queue.sync {
            var out: [UsageRow] = []
            run("SELECT day, model, input, output, cache_read, cache_write, cache_write_1h FROM usage_daily ORDER BY day") { s in
                out.append(UsageRow(
                    day: Database.text(s, 0) ?? "",
                    model: Database.text(s, 1) ?? "",
                    input: sqlite3_column_int64(s, 2),
                    output: sqlite3_column_int64(s, 3),
                    cacheRead: sqlite3_column_int64(s, 4),
                    cacheWrite: sqlite3_column_int64(s, 5),
                    cacheWrite1h: sqlite3_column_int64(s, 6)))
            }
            return out
        }
    }

    // MARK: - Loading for UI

    func loadAllSessions() -> [SessionInfo] {
        queue.sync {
            var tagsByUuid: [String: [TagInfo]] = [:]
            run("""
            SELECT st.uuid, t.id, t.name, t.color FROM session_tags st JOIN tags t ON t.id = st.tag_id
            """) { s in
                let uuid = Database.text(s, 0) ?? ""
                let tag = TagInfo(id: sqlite3_column_int64(s, 1),
                                  name: Database.text(s, 2) ?? "",
                                  colorHex: Database.text(s, 3) ?? "#7B61FF")
                tagsByUuid[uuid, default: []].append(tag)
            }

            var out: [SessionInfo] = []
            run("""
            SELECT s.uuid, s.project_dir, s.path, s.cwd, s.title, s.first_prompt, s.last_prompt,
                   s.git_branch, s.model, s.message_count, s.size, s.created_at, s.modified_at,
                   m.custom_title, m.note, m.favorite,
                   s.in_tokens, s.out_tokens, s.cache_read_tokens, s.cache_write_tokens,
                   s.cache_write_1h_tokens
            FROM sessions s LEFT JOIN meta m ON m.uuid = s.uuid
            ORDER BY s.modified_at DESC
            """) { s in
                let uuid = Database.text(s, 0) ?? ""
                var info = SessionInfo(
                    uuid: uuid,
                    projectDir: Database.text(s, 1) ?? "",
                    path: Database.text(s, 2) ?? "",
                    cwd: Database.text(s, 3),
                    title: Database.text(s, 4),
                    firstPrompt: Database.text(s, 5),
                    lastPrompt: Database.text(s, 6),
                    gitBranch: Database.text(s, 7),
                    model: Database.text(s, 8),
                    messageCount: Int(sqlite3_column_int64(s, 9)),
                    size: sqlite3_column_int64(s, 10),
                    createdAt: sqlite3_column_type(s, 11) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 11)),
                    modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 12))
                )
                info.customTitle = Database.text(s, 13)
                info.note = Database.text(s, 14)
                info.favorite = sqlite3_column_int(s, 15) == 1
                info.inputTokens = sqlite3_column_int64(s, 16)
                info.outputTokens = sqlite3_column_int64(s, 17)
                info.cacheReadTokens = sqlite3_column_int64(s, 18)
                info.cacheWriteTokens = sqlite3_column_int64(s, 19)
                info.cacheWrite1hTokens = sqlite3_column_int64(s, 20)
                info.tags = tagsByUuid[uuid] ?? []
                out.append(info)
            }
            return out
        }
    }

    // MARK: - Search

    struct SearchHit {
        var uuid: String
        var snippet: String
    }

    /// Full-text hits, best-ranked snippet per session.
    func searchContent(_ query: String, limit: Int = 400) -> [SearchHit] {
        let match = Database.ftsQuery(from: query)
        guard !match.isEmpty else { return [] }
        return queue.sync {
            var seen = Set<String>()
            var out: [SearchHit] = []
            run("""
            SELECT uuid, snippet(fts, 2, '⟪', '⟫', ' … ', 14) FROM fts
            WHERE fts MATCH ? ORDER BY rank LIMIT ?
            """, [match, limit]) { s in
                let uuid = Database.text(s, 0) ?? ""
                if seen.insert(uuid).inserted {
                    out.append(SearchHit(uuid: uuid, snippet: Database.text(s, 1) ?? ""))
                }
            }
            return out
        }
    }

    /// Escape user input into a safe FTS5 prefix query: `"foo"* "bar"*`.
    static func ftsQuery(from raw: String) -> String {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Meta (custom title / note / favorite)

    func setMeta(uuid: String, customTitle: String?, note: String?, favorite: Bool) {
        queue.sync {
            _ = run("""
            INSERT INTO meta (uuid, custom_title, note, favorite) VALUES (?,?,?,?)
            ON CONFLICT(uuid) DO UPDATE SET custom_title=excluded.custom_title,
                note=excluded.note, favorite=excluded.favorite
            """, [uuid, customTitle, note, favorite])
        }
    }

    // MARK: - Tags

    func allTags() -> [TagInfo] {
        queue.sync {
            var out: [TagInfo] = []
            run("SELECT id, name, color FROM tags ORDER BY name") { s in
                out.append(TagInfo(id: sqlite3_column_int64(s, 0),
                                   name: Database.text(s, 1) ?? "",
                                   colorHex: Database.text(s, 2) ?? "#7B61FF"))
            }
            return out
        }
    }

    @discardableResult
    func createTag(name: String, colorHex: String) -> TagInfo? {
        queue.sync {
            run("INSERT OR IGNORE INTO tags (name, color) VALUES (?,?)", [name, colorHex])
            var tag: TagInfo?
            run("SELECT id, name, color FROM tags WHERE name=?", [name]) { s in
                tag = TagInfo(id: sqlite3_column_int64(s, 0),
                              name: Database.text(s, 1) ?? "",
                              colorHex: Database.text(s, 2) ?? "#7B61FF")
            }
            return tag
        }
    }

    func deleteTag(id: Int64) {
        queue.sync {
            run("DELETE FROM session_tags WHERE tag_id=?", [id])
            run("DELETE FROM tags WHERE id=?", [id])
        }
    }

    func setTag(uuid: String, tagId: Int64, on: Bool) {
        queue.sync {
            if on {
                run("INSERT OR IGNORE INTO session_tags (uuid, tag_id) VALUES (?,?)", [uuid, tagId])
            } else {
                run("DELETE FROM session_tags WHERE uuid=? AND tag_id=?", [uuid, tagId])
            }
        }
    }

    // MARK: - Removal

    func purgeSession(uuid: String) {
        queue.sync {
            run("DELETE FROM sessions WHERE uuid=?", [uuid])
            run("DELETE FROM fts WHERE uuid=?", [uuid])
            run("DELETE FROM meta WHERE uuid=?", [uuid])
            run("DELETE FROM session_tags WHERE uuid=?", [uuid])
        }
    }
}
