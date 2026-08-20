import SwiftUI
import AppKit
import UserNotifications

/// Native macOS tabbed settings: General, Appearance, Notifications, Advanced.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "folder.badge.gearshape") }
        }
        .frame(width: 500)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("terminalKind") private var terminalKindRaw: String = TerminalKind.terminal.rawValue
    @AppStorage("claudeCommand") private var claudeCommand: String = "claude"
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Open sessions in", selection: $terminalKindRaw) {
                    ForEach(TerminalKind.allCases) { kind in
                        Text(kind.rawValue + (kind.isInstalled ? "" : " — not installed"))
                            .tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                if let caveat = TerminalKind(rawValue: terminalKindRaw)?.caveat {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Claude command", text: $claudeCommand)
                Text("Used to resume sessions. Set a full path (e.g. /opt/homebrew/bin/claude) if `claude` isn't on your terminal's PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show menu bar icon", isOn: $showMenuBarExtra)
            }
            Section {
                HStack(spacing: 10) {
                    Image("SewerkMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chatwerk \(Self.versionString)")
                            .font(.headline)
                        Text("A session manager for Claude Code — made by Sewerk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if let repo = URL(string: "https://github.com/sewerkde/chatwerk") {
                            Link("GitHub", destination: repo)
                        }
                        if let site = URL(string: "https://sewerk.de") {
                            Link("sewerk.de", destination: site)
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @AppStorage("appearance") private var appearanceRaw: String = "system"
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent color") {
                    HStack(spacing: 10) {
                        ForEach(Theme.accents, id: \.name) { item in
                            let color = Theme.dynamic(light: item.light, dark: item.dark)
                            Button {
                                accentName = item.name
                            } label: {
                                Circle()
                                    .fill(color)
                                    .frame(width: 20, height: 20)
                                    .overlay {
                                        if accentName == item.name {
                                            Circle()
                                                .stroke(color, lineWidth: 2)
                                                .frame(width: 27, height: 27)
                                        }
                                    }
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                            .accessibilityLabel(item.name)
                            .accessibilityAddTraits(accentName == item.name ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    @AppStorage("notifyWhenReady") private var notifyWhenReady: Bool = true
    @AppStorage("notifyWithBanner") private var notifyWithBanner: Bool = true
    @AppStorage("notifyWithSound") private var notifyWithSound: Bool = true
    @AppStorage("readySound") private var readySound: String = "Glass"
    @State private var bannersDenied = false

    var body: some View {
        Form {
            Section {
                Toggle("Notify when Claude is ready", isOn: $notifyWhenReady)
                Toggle("Play a sound", isOn: $notifyWithSound)
                    .disabled(!notifyWhenReady)
                Picker("Sound", selection: $readySound) {
                    ForEach(Notifier.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!notifyWhenReady || !notifyWithSound)
                .onChange(of: readySound) { _, name in
                    Notifier.preview(sound: name)
                }
                Toggle("Show a notification banner", isOn: $notifyWithBanner)
                    .disabled(!notifyWhenReady)
                    .onChange(of: notifyWithBanner) { _, on in
                        if on { Notifier.requestAuthorizationIfNeeded() }
                    }
                if bannersDenied && notifyWhenReady && notifyWithBanner {
                    HStack(spacing: 6) {
                        Text("Banners are disabled in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            Link("Open Notification Settings", destination: url)
                                .font(.caption)
                        }
                    }
                }
                Text("Fires when a running session becomes idle again — so you notice Claude is waiting for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            bannersDenied = settings.authorizationStatus == .denied
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("claudeDataDir") private var claudeDataDir: String = ""
    @AppStorage("showPlanLimits") private var showPlanLimits: Bool = false
    @State private var backupResult: String?

    var body: some View {
        Form {
            Section("Backup") {
                Button("Export Backup…") { exportBackup() }
                if let backupResult {
                    Text(backupResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Exports a dated folder with your full index (tags, notes, favorites, usage and search data) plus the app settings. To restore, quit Chatwerk and copy the backup's index.db over the index database shown below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Plan limits") {
                Toggle("Show Claude plan limits in the menu bar", isOn: $showPlanLimits)
                    .onChange(of: showPlanLimits) { _, on in
                        if on { state.refreshPlanUsage(force: true) }
                    }
                Text("Shows the same numbers as Claude Code's /usage — your 5-hour window and weekly utilization with reset times. Chatwerk reads Claude Code's own login token from your Keychain (macOS asks once; choose “Always Allow”) and talks only to api.anthropic.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Claude Code data") {
                LabeledContent("Data folder") {
                    HStack(spacing: 6) {
                        TextField("~/.claude (default)", text: $claudeDataDir)
                            .frame(minWidth: 180)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                claudeDataDir = url.path
                            }
                        }
                    }
                }
                Text("Leave empty for the default ~/.claude. Only change this if you run Claude Code with CLAUDE_CONFIG_DIR. Restart Chatwerk after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                LabeledContent("Index database") {
                    Text(ClaudePaths.databaseURL.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Text("Chatwerk reads your Claude Code data locally and never sends it anywhere. Notes, tags and favorites are stored only in the index database above — never inside ~/.claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let folder = try state.exportBackup(to: url)
            backupResult = "Backup written to “\(folder.lastPathComponent)”."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            backupResult = "Backup failed: \(error.localizedDescription)"
        }
    }
}
