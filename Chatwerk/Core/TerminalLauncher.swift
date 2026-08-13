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
            copyToClipboard(command)
            if let cwd = session.cwd,
               let url = URL(string: "warp://action/new_tab?path=" + (cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cwd)) {
                NSWorkspace.shared.open(url)
            }
            return .copiedToClipboard(reason: "Warp can't run commands via automation — the resume command is on your clipboard, just paste it (⌘V) into the new tab.")
        }
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
        args.append(contentsOf: ["-e", command])
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
