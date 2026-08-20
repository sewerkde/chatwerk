import Foundation
import AppKit

/// Opens a session's resume command in the user's preferred terminal.
enum TerminalLauncher {

    enum LaunchResult {
        case opened
        case copiedToClipboard(reason: String)
        case failed(String)
    }

    static func open(session: SessionInfo, terminal: TerminalKind, claudeCommand: String) -> LaunchResult {
        var command = session.resumeCommand
        if claudeCommand != "claude" {
            command = command.replacingOccurrences(of: "claude --resume", with: "\(claudeCommand) --resume")
        }
        if let cwd = session.cwd, !FileManager.default.fileExists(atPath: cwd) {
            return .failed("Project directory no longer exists:\n\(cwd)")
        }
        switch terminal {
        case .terminal:
            return runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(escapeForAppleScript(command))"
            end tell
            """)
        case .iterm:
            return runAppleScript("""
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(escapeForAppleScript(command))"
                end tell
            end tell
            """)
        case .ghostty:
            return launchGhostty(session: session, command: command)
        case .warp:
            return launchWarp(command: command)
        }
    }

    /// Warp can't be scripted reliably (no AppleScript; launch-config URLs
    /// proved fragile across versions) — so Chatwerk copies the resume
    /// command and brings Warp to the front. One paste and you're back in.
    private static func launchWarp(command: String) -> LaunchResult {
        copyToClipboard(command)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp") else {
            return .failed("Warp doesn't seem to be installed — the resume command is on your clipboard.")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return .copiedToClipboard(reason: "Warp opened — the resume command is on your clipboard. Paste (⌘V) and press ↩.")
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> LaunchResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not build AppleScript.")
        }
        script.executeAndReturnError(&error)
        if let error {
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? "\(error)"
            return .failed(msg)
        }
        return .opened
    }

    private static func launchGhostty(session: SessionInfo, command: String) -> LaunchResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-na", "Ghostty", "--args"]
        if let cwd = session.cwd {
            args.append("--working-directory=\(cwd)")
        }
        // Ghostty's -e execs its arguments directly (no shell), so the
        // compound `cd … && claude …` command needs an explicit shell.
        args.append(contentsOf: ["-e", "/bin/zsh", "-lc", command])
        proc.arguments = args
        do {
            try proc.run()
            return .opened
        } catch {
            copyToClipboard(command)
            return .copiedToClipboard(reason: "Ghostty could not be launched — the resume command is on your clipboard instead.")
        }
    }
}
