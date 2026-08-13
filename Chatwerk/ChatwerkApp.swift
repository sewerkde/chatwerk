import SwiftUI

@main
struct ChatwerkApp: App {
    @StateObject private var state = AppState()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true
    @AppStorage("appearance") private var appearanceRaw: String = "system"
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(Theme.scheme(appearanceRaw))
                .tint(Theme.accent(accentName))
        }
        .commands {
            // Single-window app: "File > New Window" only confuses.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                Button("Continue in \(state.terminalKind.rawValue)") {
                    if let s = state.selectedSession { state.open(s) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.selectedSession == nil)
                Button("Copy Resume Command") {
                    if let s = state.selectedSession { state.copyCommand(s) }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(state.selectedSession == nil)
                Divider()
                Button(state.selectedSession?.favorite == true ? "Remove from Favorites" : "Add to Favorites") {
                    if let s = state.selectedSession { state.toggleFavorite(s) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(state.selectedSession == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .preferredColorScheme(Theme.scheme(appearanceRaw))
                .tint(Theme.accent(accentName))
        }

        MenuBarExtra("Chatwerk", image: "MenuBarIcon", isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environmentObject(state)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("notifyWhenReady") private var notifyWhenReady = true

    var body: some View {
        Text("Recent sessions")
        ForEach(state.sessions.prefix(10)) { session in
            Button {
                state.open(session)
            } label: {
                Text(menuTitle(session))
            }
        }
        Divider()
        Toggle("Alert when Claude is ready", isOn: $notifyWhenReady)
        Divider()
        Button("Open Chatwerk") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Chatwerk") {
            NSApp.terminate(nil)
        }
    }

    private func menuTitle(_ s: SessionInfo) -> String {
        let title = s.displayTitle
        let short = title.count > 50 ? String(title.prefix(50)) + "…" : title
        let badge = s.isWaitingForYou ? "🟠 " : (s.isLive ? "🟢 " : "")
        return badge + short
    }
}
