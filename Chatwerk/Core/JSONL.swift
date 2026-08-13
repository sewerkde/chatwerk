import Foundation

/// Helpers for reading Claude Code JSONL transcripts without loading whole files
/// (individual transcripts can exceed 250 MB, single lines can be multi-MB).
enum JSONL {

    static let maxLineBytes = 64 * 1024 * 1024

    static func parseLine(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Read complete lines starting at `offset`.
    /// - `dropFirstPartial`: set when `offset` may fall mid-line (tail reads);
    ///   the first line fragment is then discarded.
    /// - Grows the read window when no newline fits in `length`; a pathological
    ///   line above `maxLineBytes` is skipped entirely.
    /// - `nextOffset` always lands on a line boundary, so callers can resume there.
    static func readLines(path: String, offset: UInt64, length: Int, dropFirstPartial: Bool = false)
        -> (lines: [Data], nextOffset: UInt64, atEOF: Bool)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        var readLen = length
        while true {
            do {
                try fh.seek(toOffset: offset)
                let data = (try fh.read(upToCount: readLen)) ?? Data()
                if data.isEmpty { return (lines: [], nextOffset: offset, atEOF: true) }
                let atEOF = data.count < readLen

                var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
                var consumed = data.count
                if data.last != UInt8(ascii: "\n"), !atEOF, let last = lines.popLast() {
                    consumed -= last.count   // trailing partial line: leave for next read
                }
                if dropFirstPartial, offset > 0, !lines.isEmpty {
                    lines.removeFirst()
                }

                if lines.isEmpty, !atEOF {
                    if readLen < maxLineBytes {
                        readLen = min(readLen * 4, maxLineBytes)
                        continue
                    }
                    // Single line larger than maxLineBytes — skip it.
                    let next = skipToNextNewline(fh: fh, from: offset + UInt64(data.count))
                    return (lines: [], nextOffset: next, atEOF: false)
                }
                return (lines: lines, nextOffset: offset + UInt64(consumed), atEOF: atEOF)
            } catch {
                return nil
            }
        }
    }

    private static func skipToNextNewline(fh: FileHandle, from: UInt64) -> UInt64 {
        var pos = from
        while true {
            try? fh.seek(toOffset: pos)
            guard let d = try? fh.read(upToCount: 8 * 1024 * 1024), !d.isEmpty else { return pos }
            if let idx = d.firstIndex(of: UInt8(ascii: "\n")) {
                return pos + UInt64(idx) + 1
            }
            pos += UInt64(d.count)
        }
    }

    /// Extract plain text from a message object (`message.content` is either a
    /// string or an array of typed blocks).
    static func messageText(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Human-typed prompt heuristic: skip command wrappers, tool results and
    /// harness notifications that also arrive as `type:"user"` lines.
    static func isNoiseText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        for prefix in ["<command-", "<local-command", "<task-notification", "<system-reminder", "[Request interrupted"] {
            if t.hasPrefix(prefix) { return true }
        }
        return false
    }

    static func cleanPrompt(_ text: String, maxLength: Int = 200) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        if t.count > maxLength {
            t = String(t.prefix(maxLength)) + "…"
        }
        return t
    }

    /// Fast pre-filter so we only JSON-parse lines we care about.
    static func lineHasPrefix(_ data: Data, anyOf prefixes: [String]) -> Bool {
        guard let head = String(data: data.prefix(24), encoding: .utf8) else { return false }
        return prefixes.contains { head.hasPrefix($0) }
    }
}
