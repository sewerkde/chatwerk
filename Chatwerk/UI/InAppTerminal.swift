import SwiftUI
import AppKit
import SwiftTerm

/// A real PTY-backed terminal inside Chatwerk running `claude --resume`,
/// so sessions can be continued without leaving the app — with the full
/// Claude Code TUI (permission prompts, colors, shortcuts) intact.
///
/// Windows are opened directly via AppKit (not a SwiftUI WindowGroup) so
/// "Continue in Chatwerk" deterministically opens in-app.
@MainActor
final class TerminalWindowManager {
    static let shared = TerminalWindowManager()
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func open(session: SessionInfo, command: String) {
        if let existing = windows[session.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: TerminalPane(command: command))
        let window = NSWindow(contentViewController: hosting)
        window.title = session.displayTitle
        window.subtitle = session.cwd ?? ""
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[session.id] = window
        closeObservers[session.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windows.removeValue(forKey: session.id)
                if let token = self.closeObservers.removeValue(forKey: session.id) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
    }
}

struct TerminalPane: View {
    let command: String

    var body: some View {
        TerminalHostView(command: command)
            .frame(minWidth: 480, minHeight: 320)
    }
}

struct TerminalHostView: NSViewRepresentable {
    let command: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.processDelegate = context.coordinator

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envList = env.map { "\($0.key)=\($0.value)" }

        // Login shell so the user's PATH (homebrew, nvm, …) resolves `claude`.
        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-c", command],
                          environment: envList)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                source.window?.close()
            }
        }
    }
}
