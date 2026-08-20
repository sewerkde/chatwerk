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
            CommandGroup(after: .sidebar) {
                Button("Quick Search…") {
                    state.showQuickSearch = true
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
            }
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
            MenuBarPanel()
                .environmentObject(state)
                .tint(Theme.accent(accentName))
        }
        .menuBarExtraStyle(.window)
    }
}
