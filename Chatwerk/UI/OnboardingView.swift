import SwiftUI
import AppKit

/// First-launch setup: a short hero, three feature rows, the terminal picker
/// and the ready-alert toggle. Only terminals actually installed are offered.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminalKind") private var terminalKindRaw: String = TerminalKind.terminal.rawValue
    @AppStorage("didOnboard") private var didOnboard = false
    @AppStorage("notifyWhenReady") private var notifyWhenReady = true
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"
    private var accent: Color { Theme.accent(accentName) }

    private let installed = TerminalKind.installed

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                Text("Welcome to Chatwerk")
                    .font(.largeTitle.bold())
                Text("All your Claude Code chats in one place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "magnifyingglass", title: "Search every chat",
                           text: "Full-text search across all your sessions — titles, notes and content.")
                featureRow(icon: "tag", title: "Tag & organize",
                           text: "Favorites, notes and tags, stored locally — nothing leaves your Mac.")
                featureRow(icon: "play.circle", title: "Resume in one click",
                           text: "Jump back into any session, right in your own terminal.")
            }
            .frame(maxWidth: 400, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("Where should sessions open?")
                    .font(.headline)

                ForEach(installed) { kind in
                    let isSelected = terminalKindRaw == kind.rawValue
                    Button {
                        terminalKindRaw = kind.rawValue
                    } label: {
                        HStack {
                            Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                                .foregroundStyle(isSelected ? accent : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.rawValue)
                                if let caveat = kind.caveat {
                                    Text(caveat)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            isSelected ? accent.opacity(0.1) : Color.secondary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? accent : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.vertical, 2)

                Toggle("Notify me (sound + banner) when Claude is ready", isOn: $notifyWhenReady)

                Text("You can change all of this anytime in Settings (⌘,) or from the menu bar icon.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 400)

            Button {
                didOnboard = true
                if notifyWhenReady {
                    Notifier.requestAuthorizationIfNeeded()
                }
                dismiss()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 500)
        .onAppear {
            // Preselect the first installed terminal if the saved one is missing.
            if !(TerminalKind(rawValue: terminalKindRaw)?.isInstalled ?? false),
               let first = installed.first {
                terminalKindRaw = first.rawValue
            }
        }
    }

    private func featureRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
