import SwiftUI
import AppKit

/// The menu bar panel: plan limits with progress bars, local usage, recent
/// sessions and quick actions. Rendered as a window-style extra because the
/// default menu grays out informational rows as if they were disabled.
struct MenuBarPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notifyWhenReady") private var notifyWhenReady = true
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"

    private var accent: Color { Theme.accent(accentName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.showPlanLimits {
                planSection
                Divider()
            }
            usageSection
            Divider()
            recentsSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { state.refreshPlanUsage() }
    }

    // MARK: - Plan limits

    private static let isoParser = ISO8601DateFormatter()

    @ViewBuilder
    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Plan Limits")
            if let plan = state.planUsage {
                planRow("5h window", plan.fiveHour)
                planRow("This week", plan.sevenDay)
                if let opus = plan.sevenDayOpus, opus.utilization != nil {
                    planRow("Week · Opus", opus)
                }
                if let sonnet = plan.sevenDaySonnet, sonnet.utilization != nil {
                    planRow("Week · Sonnet", sonnet)
                }
            } else {
                Text(state.planUsageError ?? "Loading plan limits…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func planRow(_ label: String, _ window: PlanUsage.Window?) -> some View {
        let value = window?.utilization ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", value))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if let raw = window?.resetsAt, let date = Self.isoParser.date(from: raw) {
                    Text("resets \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: min(value, 100), total: 100)
                .tint(value >= 90 ? .red : value >= 70 ? .orange : accent)
                .controlSize(.small)
        }
    }

    // MARK: - Local usage

    private var usageSection: some View {
        let usage = state.usageSummary()
        return VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Usage · est. API price")
            usageRow("Last 5h", usage.window5h)
            usageRow("Today", usage.today)
            usageRow("Last 7 days", usage.last7d)
            usageRow("This month", usage.month)
        }
    }

    private func usageRow(_ label: String, _ period: AppState.UsagePeriod) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(period.tokens.tokenString) · \(Pricing.dollars(period.cost))")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
    }

    // MARK: - Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Recent Sessions")
            if state.sessions.isEmpty {
                Text("No sessions yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.sessions.prefix(5)) { session in
                PanelRow {
                    dismiss()
                    state.open(session)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(session.isWaitingForYou ? Color.orange
                                  : session.isWorking ? Color.green
                                  : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        Text(session.displayTitle)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Notify when Claude is ready", isOn: $notifyWhenReady)
                .toggleStyle(.checkbox)
                .font(.caption)
            HStack {
                Button("Open Chatwerk") {
                    dismiss()
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// Menu-like row with a hover highlight.
private struct PanelRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}
