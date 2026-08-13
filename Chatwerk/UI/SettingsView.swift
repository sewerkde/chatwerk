import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("terminalKind") private var terminalKindRaw: String = TerminalKind.terminal.rawValue
    @AppStorage("claudeCommand") private var claudeCommand: String = "claude"
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true
    @AppStorage("notifyWhenReady") private var notifyWhenReady: Bool = true
    @AppStorage("notifyWithBanner") private var notifyWithBanner: Bool = true
    @AppStorage("notifyWithSound") private var notifyWithSound: Bool = true
    @AppStorage("readySound") private var readySound: String = "Glass"
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
                    HStack(spacing: 8) {
                        ForEach(Theme.accents, id: \.name) { item in
                            let color = Color(hex: item.hex) ?? .orange
                            Circle()
                                .fill(color)
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if accentName == item.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { accentName = item.name }
                                .help(item.name)
                        }
                    }
                }
            }

            Section {
                Picker("Terminal app", selection: $terminalKindRaw) {
                    ForEach(TerminalKind.allCases) { kind in
                        Text(kind.rawValue + (kind.isInstalled ? "" : " — not installed"))
                            .tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("Warp is driven via a Launch Configuration, so the resume command runs automatically (and is also copied to your clipboard as a fallback).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Alert when Claude finishes responding", isOn: $notifyWhenReady)
                Toggle("Play a sound", isOn: $notifyWithSound)
                    .disabled(!notifyWhenReady)
                HStack {
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
                    Button {
                        Notifier.preview(sound: readySound)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .disabled(!notifyWhenReady || !notifyWithSound)
                    .help("Preview sound")
                }
                Toggle("Show a notification banner", isOn: $notifyWithBanner)
                    .disabled(!notifyWhenReady)
                    .onChange(of: notifyWithBanner) { _, on in
                        if on { Notifier.requestAuthorizationIfNeeded() }
                    }
                Text("Fires when a running session becomes idle again — so you notice Claude is waiting for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Claude command", text: $claudeCommand)
                    .help("Command used to resume sessions. Change it if `claude` is not on your terminal's PATH, e.g. /opt/homebrew/bin/claude")
                Toggle("Show menu bar icon", isOn: $showMenuBarExtra)
            }

            Section {
                LabeledContent("Data folder") {
                    Text(ClaudePaths.claudeDir.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Index database") {
                    Text(ClaudePaths.databaseURL.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Text("Chatwerk reads your Claude Code data locally and never sends it anywhere. Notes, tags and favorites are stored only in the index database above — never inside ~/.claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Image("SewerkMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chatwerk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                            .font(.headline)
                        Text("A session manager for Claude Code — made by Sewerk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("sewerk.de", destination: URL(string: "https://sewerk.de")!)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
