import SwiftUI

@main
struct ChatwerkApp: App {
    @StateObject private var state = AppState()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 620)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }

        MenuBarExtra("Chatwerk", systemImage: "bubble.left.and.text.bubble.right", isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environmentObject(state)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

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
        return (s.isLive ? "🟢 " : "") + short
    }
}
