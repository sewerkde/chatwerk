import SwiftUI
import AppKit
import SwiftTerm

/// A real PTY-backed terminal inside Chatwerk running `claude --resume`,
/// so sessions can be continued without leaving the app — with the full
/// Claude Code TUI (permission prompts, colors, shortcuts) intact.
struct SessionTerminalWindow: View {
    @EnvironmentObject var state: AppState
    let sessionId: String?

    var body: some View {
        if let sessionId,
           let session = state.sessions.first(where: { $0.id == sessionId }) {
            TerminalHostView(command: state.shellCommand(for: session))
                .navigationTitle(session.displayTitle)
                .frame(minWidth: 640, minHeight: 420)
        } else {
            ContentUnavailableView("Session not found", systemImage: "questionmark.bubble")
                .frame(minWidth: 400, minHeight: 300)
        }
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
