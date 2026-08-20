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
        if state.showPlanLimits {
            Section("Plan Limits") {
                if let plan = state.planUsage {
                    Text("5h window: \(percent(plan.fiveHour))\(resetSuffix(plan.fiveHour))")
                    Text("This week: \(percent(plan.sevenDay))\(resetSuffix(plan.sevenDay))")
                    if let opus = plan.sevenDayOpus, opus.utilization != nil {
                        Text("Week (Opus): \(percent(opus))")
                    }
                    if let sonnet = plan.sevenDaySonnet, sonnet.utilization != nil {
                        Text("Week (Sonnet): \(percent(sonnet))")
                    }
                } else {
                    Text(state.planUsageError ?? "Loading plan limits…")
                }
            }
        }
        Section("Usage") {
            let usage = state.usageSummary()
            Text("Last 5h: \(usage.window5h.tokens.tokenString) tokens · \(Pricing.dollars(usage.window5h.cost))")
            Text("Today: \(usage.today.tokens.tokenString) · \(Pricing.dollars(usage.today.cost))")
            Text("Last 7 days: \(usage.last7d.tokens.tokenString) · \(Pricing.dollars(usage.last7d.cost))")
            Text("This month: \(usage.month.tokens.tokenString) · \(Pricing.dollars(usage.month.cost))")
        }
        Section("Recent Sessions") {
            if state.sessions.isEmpty {
                Text("No sessions yet")
            }
            ForEach(state.sessions.prefix(10)) { session in
                Button {
                    state.open(session)
                } label: {
                    Label(menuTitle(session), systemImage: menuSymbol(session))
                }
            }
        }
        Divider()
        Toggle("Notify when Claude is ready", isOn: $notifyWhenReady)
        Divider()
        Button("Open Chatwerk") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Quit Chatwerk") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func menuTitle(_ s: SessionInfo) -> String {
        let title = s.displayTitle
        return title.count > 50 ? String(title.prefix(50)) + "…" : title
    }

    /// Menus render template-only, so status is encoded in symbol shape:
    /// waiting → exclamation bubble, working → ellipsis bubble, else plain.
    private func menuSymbol(_ s: SessionInfo) -> String {
        if s.isWaitingForYou { return "exclamationmark.bubble.fill" }
        if s.isWorking { return "ellipsis.bubble.fill" }
        return "bubble.left"
    }

    private static let isoParser = ISO8601DateFormatter()

    private func percent(_ window: PlanUsage.Window?) -> String {
        guard let value = window?.utilization else { return "—" }
        return String(format: "%.0f%% used", value)
    }

    private func resetSuffix(_ window: PlanUsage.Window?) -> String {
        guard let raw = window?.resetsAt,
              let date = Self.isoParser.date(from: raw) else { return "" }
        return " · resets \(date.formatted(date: .omitted, time: .shortened))"
    }
}
