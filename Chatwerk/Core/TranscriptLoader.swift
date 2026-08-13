import Foundation

/// One rendered entry in the transcript viewer.
struct TranscriptEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case user
        case assistant
        case thinking
        case toolUse(name: String)
        case toolResult
    }
    var id: Int
    var kind: Kind
    var text: String
    var timestamp: Date?

    var roleLabel: String {
        switch kind {
        case .user: return "You"
        case .assistant: return "Claude"
        case .thinking: return "Thinking"
        case .toolUse(let name): return "Tool · \(name)"
        case .toolResult: return "Tool result"
        }
    }
}

struct TranscriptPage {
    var entries: [TranscriptEntry]
    var totalEntries: Int
    var truncatedHead: Bool     // true when older entries were dropped for memory
}

/// Streams a transcript and keeps only the newest `maxEntries` in memory,
/// so 250 MB sessions stay viewable.
enum TranscriptLoader {

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Reads only the last `tailBytes` of huge transcripts so the viewer opens
    /// instantly, and cooperates with Task cancellation so rapid clicking
    /// through sessions doesn't stack full-file reads.
    static func load(path: String, maxEntries: Int = 500, tailBytes: Int64 = 8 * 1024 * 1024) -> TranscriptPage {
        var ring: [TranscriptEntry] = []
        ring.reserveCapacity(maxEntries + 64)
        var total = 0
        var nextId = 0
        let chunkSize = 4 * 1024 * 1024

        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64) ?? 0
        var offset: UInt64 = 0
        var skippedHead = false
        if size > tailBytes {
            offset = UInt64(size - tailBytes)
            skippedHead = true
        }
        var firstRead = true

        while true {
            if Task.isCancelled { break }
            guard let chunk = JSONL.readLines(path: path, offset: offset, length: chunkSize,
                                              dropFirstPartial: firstRead && skippedHead) else { break }
            firstRead = false
            for line in chunk.lines {
                guard JSONL.lineHasPrefix(line, anyOf: ["{\"parentUuid\"", "{\"type\":\"user\"", "{\"type\":\"assistant\""]) else { continue }
                guard let obj = JSONL.parseLine(line) else { continue }
                guard let type = obj["type"] as? String, type == "user" || type == "assistant" else { continue }
                guard (obj["isSidechain"] as? Bool) != true else { continue }
                guard let message = obj["message"] as? [String: Any] else { continue }

                let ts = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }

                for entry in entries(from: message, type: type, timestamp: ts, nextId: &nextId) {
                    total += 1
                    ring.append(entry)
                    if ring.count > maxEntries + 64 {
                        ring.removeFirst(ring.count - maxEntries)
                    }
                }
            }
            if chunk.atEOF || chunk.nextOffset <= offset { break }
            offset = chunk.nextOffset
        }

        let truncated = skippedHead || ring.count < total
        if ring.count > maxEntries {
            ring.removeFirst(ring.count - maxEntries)
        }
        return TranscriptPage(entries: ring, totalEntries: total, truncatedHead: truncated)
    }

    private static func entries(from message: [String: Any], type: String,
                                timestamp: Date?, nextId: inout Int) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []

        func add(_ kind: TranscriptEntry.Kind, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            out.append(TranscriptEntry(id: nextId, kind: kind, text: String(t.prefix(40_000)), timestamp: timestamp))
            nextId += 1
        }

        if let s = message["content"] as? String {
            if type == "user", JSONL.isNoiseText(s) { return out }
            add(type == "user" ? .user : .assistant, s)
            return out
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return out }
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String {
                    add(type == "user" ? .user : .assistant, t)
                }
            case "thinking":
                if let t = block["thinking"] as? String {
                    add(.thinking, t)
                }
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                var summary = ""
                if let input = block["input"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: data, encoding: .utf8) {
                    summary = s
                }
                add(.toolUse(name: name), summary.isEmpty ? name : summary)
            case "tool_result":
                var text = ""
                if let s = block["content"] as? String {
                    text = s
                } else if let arr = block["content"] as? [[String: Any]] {
                    text = arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                }
                add(.toolResult, text)
            default:
                break
            }
        }
        return out
    }

    /// Markdown → plain sentence for previews (the "where you left off" card):
    /// drops fences, heading markers, emphasis and link syntax, collapses
    /// whitespace so raw `##`/`**` noise never reaches the UI.
    static func plainPreview(_ text: String, maxLength: Int = 600) -> String {
        var t = text
        t = t.replacingOccurrences(of: "```[a-zA-Z0-9]*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^[-*+]\\s+", with: "• ", options: .regularExpression)
        for marker in ["**", "__", "`", "~~"] {
            t = t.replacingOccurrences(of: marker, with: "")
        }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxLength {
            t = String(t.prefix(maxLength)) + "…"
        }
        return t
    }

    // MARK: - Export

    static func exportMarkdown(session: SessionInfo, page: TranscriptPage) -> String {
        var md = "# \(session.displayTitle)\n\n"
        md += "- Session: `\(session.uuid)`\n"
        if let cwd = session.cwd { md += "- Project: `\(cwd)`\n" }
        md += "- Last activity: \(session.modifiedAt.formatted())\n"
        md += "- Resume: `\(session.resumeCommand)`\n\n---\n\n"
        if page.truncatedHead {
            md += "> Note: only the last \(page.entries.count) entries are included.\n\n"
        }
        for e in page.entries {
            switch e.kind {
            case .user: md += "### 🧑 You\n\n\(e.text)\n\n"
            case .assistant: md += "### 🤖 Claude\n\n\(e.text)\n\n"
            case .thinking: md += "<details><summary>Thinking</summary>\n\n\(e.text)\n\n</details>\n\n"
            case .toolUse(let name): md += "<details><summary>Tool: \(name)</summary>\n\n```json\n\(e.text)\n```\n\n</details>\n\n"
            case .toolResult: md += "<details><summary>Tool result</summary>\n\n```\n\(e.text)\n```\n\n</details>\n\n"
            }
        }
        return md
    }
}
