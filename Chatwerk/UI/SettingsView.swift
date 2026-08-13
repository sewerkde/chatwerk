import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("terminalKind") private var terminalKindRaw: String = TerminalKind.terminal.rawValue
    @AppStorage("claudeCommand") private var claudeCommand: String = "claude"
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    var body: some View {
        Form {
            Section {
                Picker("Open sessions in", selection: $terminalKindRaw) {
                    ForEach(TerminalKind.allCases) { kind in
                        Text(kind.rawValue + (kind.isInstalled ? "" : " — not installed"))
                            .tag(kind.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("Warp cannot run commands via automation — Chatwerk opens a tab in the project folder and puts the resume command on your clipboard.")
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
