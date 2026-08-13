import Foundation
import SwiftUI
import AppKit

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

    // aggregated token usage (filled by the indexer)
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cacheReadTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var cacheWrite1hTokens: Int64 = 0

    /// Estimated cost in dollars, when the model's pricing is known.
    var estimatedCost: Double? {
        guard let model else { return nil }
        return Pricing.cost(model: model, input: inputTokens, output: outputTokens,
                            cacheRead: cacheReadTokens, cacheWrite: cacheWriteTokens,
                            cacheWrite1h: cacheWrite1hTokens)
    }

    // user metadata (stored only in Chatwerk's own DB, never in ~/.claude)
    var customTitle: String?
    var note: String?
    var favorite: Bool = false
    var tags: [TagInfo] = []

    // transient
    var isLive: Bool = false
    var liveStatus: String?    // "idle", "busy", … from ~/.claude/sessions
    var searchSnippet: String?

    /// Running and idle → Claude answered and is waiting for the user.
    var isWaitingForYou: Bool { isLive && liveStatus == "idle" }
    /// Running and not idle → Claude is still working.
    var isWorking: Bool { isLive && liveStatus != "idle" }

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
    case expiring          // close to Claude Code's cleanupPeriodDays auto-delete
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
            ? "Opens via a Warp Launch Configuration — the resume command runs automatically. It's also copied to your clipboard as a fallback for older Warp versions."
            : nil
    }

    static var installed: [TerminalKind] { allCases.filter(\.isInstalled) }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// User-selectable appearance + accent themes.
/// Every accent has a light and a brighter dark variant — low-opacity warm
/// colors go muddy brown on dark backgrounds otherwise.
enum Theme {
    static let accents: [(name: String, light: String, dark: String)] = [
        ("Sewerk Orange", "#FF6A00", "#FF9142"),
        ("Purple", "#7B61FF", "#9D8AFF"),
        ("Violet", "#9B5CF6", "#B685FF"),
        ("Blue", "#339AF0", "#66B8FF"),
        ("Green", "#2F9E44", "#69DB7C"),
        ("Lime", "#82C91E", "#A9E34B"),
        ("Pink", "#F06595", "#FF8CB3"),
        ("Teal", "#12B886", "#4FDBB5"),
    ]

    /// A color that resolves per-appearance (brighter variant in dark mode).
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light) ?? .orange)
        })
    }

    static func accent(_ name: String) -> Color {
        let entry = accents.first { $0.name == name } ?? accents[0]
        return dynamic(light: entry.light, dark: entry.dark)
    }

    /// Session-state row tints (semantic, independent of the chosen accent).
    static var waitingRowTint: Color { dynamic(light: "#FF6A00", dark: "#FFB340").opacity(0.16) }
    static var workingRowTint: Color { dynamic(light: "#2F9E44", dark: "#69DB7C").opacity(0.10) }

    static func scheme(_ raw: String) -> ColorScheme? {
        switch raw {
        case "light": return .light
        case "dark": return .dark
        default: return nil    // follow system
        }
    }
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

// Formatters are expensive to create; list rows render them constantly.
private let sharedByteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f
}()

private let sharedRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    f.dateTimeStyle = .named
    return f
}()

extension Int64 {
    var byteString: String {
        sharedByteFormatter.string(fromByteCount: self)
    }
}

extension Date {
    var relativeString: String {
        sharedRelativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}
