import SwiftUI

/// First-launch setup: pick the terminal Chatwerk should resume sessions in.
/// Only terminals actually installed on this Mac are offered.
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
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image("SewerkMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                Text("Welcome to Chatwerk")
                    .font(.title.bold())
                Text("All your Claude Code chats in one place — search them, tag them,\nand jump back in with a single click.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Where should sessions open?")
                    .font(.headline)
                Text("Chatwerk found these terminals on your Mac:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(installed) { kind in
                    Button {
                        terminalKindRaw = kind.rawValue
                    } label: {
                        HStack {
                            Image(systemName: terminalKindRaw == kind.rawValue ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(terminalKindRaw == kind.rawValue ? accent : .secondary)
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
                            terminalKindRaw == kind.rawValue ? accent.opacity(0.1) : Color.secondary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.vertical, 2)

                Toggle("Play a sound when Claude finishes responding", isOn: $notifyWhenReady)

                Text("You can change all of this anytime in Settings (⌘,) or from the menu bar icon.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 380)

            Button {
                didOnboard = true
                dismiss()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 480)
        .onAppear {
            // Preselect the first installed terminal if the saved one is missing.
            if !(TerminalKind(rawValue: terminalKindRaw)?.isInstalled ?? false),
               let first = installed.first {
                terminalKindRaw = first.rawValue
            }
        }
    }

}
