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
            let resumeOnly = command.components(separatedBy: " && ").last ?? command
            return launchWarp(session: session, resumeCommand: resumeOnly, fullCommand: command)
        }
    }

    /// Warp can't be driven by AppleScript, but it supports Launch
    /// Configurations: a YAML file ("open this cwd, run these commands")
    /// opened through the warp:// URL scheme — so resume runs automatically.
    private static func launchWarp(session: SessionInfo, resumeCommand: String, fullCommand: String) -> LaunchResult {
        let dir = ClaudePaths.appSupportDir.appendingPathComponent("warp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appendingPathComponent("chatwerk-resume.yaml")
        let cwd = session.cwd ?? NSHomeDirectory()
        let yaml = """
        ---
        name: chatwerk-resume
        windows:
          - tabs:
              - title: \(yamlQuote("Claude · " + session.displayTitle.prefix(40)))
                layout:
                  cwd: \(yamlQuote(cwd))
                  commands:
                    - exec: \(yamlQuote(resumeCommand))
        """
        // Fallback for older Warp versions stays on the clipboard.
        copyToClipboard(fullCommand)
        do {
            try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            return .copiedToClipboard(reason: "Couldn't prepare the Warp launch file — the resume command is on your clipboard, paste it (⌘V) into Warp.")
        }
        guard let encoded = configURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "warp://launch/" + encoded),
              NSWorkspace.shared.open(url) else {
            return .copiedToClipboard(reason: "Warp didn't accept the launch request — the resume command is on your clipboard, paste it (⌘V) into a Warp tab.")
        }
        return .opened
    }

    private static func yamlQuote(_ s: any StringProtocol) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
