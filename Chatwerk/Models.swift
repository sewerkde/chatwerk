import Foundation
import SwiftUI

/// One Claude Code session (a <uuid>.jsonl transcript under ~/.claude/projects/<encoded-cwd>/).
struct SessionInfo: Identifiable, Hashable {
    var id: String { projectDir + "/" + uuid }
    var uuid: String
    var projectDir: String     // encoded directory name, e.g. "-Users-developer"
    var path: String           // absolute path to the .jsonl transcript
    var cwd: String?           // real working directory read from inside the JSONL
    var title: String?         // auto title (ai-title line, else first prompt)
    var firstPrompt: String?
    var lastPrompt: String?
    var gitBranch: String?
    var model: String?
    var messageCount: Int
    var size: Int64
    var createdAt: Date?
    var modifiedAt: Date

    // user metadata (stored only in Chatwerk's own DB, never in ~/.claude)
    var customTitle: String?
    var note: String?
    var favorite: Bool = false
    var tags: [TagInfo] = []

    // transient
    var isLive: Bool = false
    var searchSnippet: String?

    var displayTitle: String {
        if let t = customTitle, !t.isEmpty { return t }
        if let t = title, !t.isEmpty { return t }
        if let p = lastPrompt, !p.isEmpty { return p }
        return String(uuid.prefix(8))
    }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return projectDir }
        return (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent
    }

    /// Not yet organized by the user in any way — candidates for getting lost.
    var isUnsorted: Bool {
        tags.isEmpty && !favorite
            && (note ?? "").isEmpty
            && (customTitle ?? "").isEmpty
    }

    var resumeCommand: String {
        let cd: String
        if let cwd, !cwd.isEmpty {
            cd = "cd \(shellQuote(cwd)) && "
        } else {
            cd = ""
        }
        return cd + "claude --resume \(uuid)"
    }
}

struct TagInfo: Identifiable, Hashable {
    var id: Int64
    var name: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) ?? .accentColor }
}

/// A distinct project (grouped by real cwd).
struct ProjectGroup: Identifiable, Hashable {
    var id: String { key }
    var key: String            // cwd if known, else encoded dir
    var name: String
    var sessionCount: Int
    var totalSize: Int64
}

enum SidebarFilter: Hashable {
    case all
    case favorites
    case live
    case unsorted          // sessions with no tag/note/favorite — the "forgotten" pool
    case project(String)   // ProjectGroup.key
    case tag(Int64)        // tag id
}

enum TerminalKind: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm2"
    case ghostty = "Ghostty"
    case warp = "Warp"
    var id: String { rawValue }

    var bundleIds: [String] {
        switch self {
        case .terminal: return ["com.apple.Terminal"]
        case .iterm: return ["com.googlecode.iterm2"]
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .warp: return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        }
    }

    var isInstalled: Bool {
        bundleIds.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    var caveat: String? {
        self == .warp
            ? "Warp can't run commands via automation — Chatwerk opens the project folder and copies the command to your clipboard."
            : nil
    }

    static var installed: [TerminalKind] { allCases.filter(\.isInstalled) }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0
        )
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
