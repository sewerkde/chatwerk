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
    @AppStorage("openInApp") private var openInApp = false

    var body: some View {
        Text("Recent sessions")
        ForEach(state.sessions.prefix(10)) { session in
            Button {
                state.continueDefault(session)
            } label: {
                Text(menuTitle(session))
            }
        }
        Divider()
        Toggle("Alert when Claude is ready", isOn: $notifyWhenReady)
        Toggle("Continue sessions inside Chatwerk", isOn: $openInApp)
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
