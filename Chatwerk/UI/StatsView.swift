import SwiftUI
import Charts

struct StatsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"

    @State private var usageRows: [Database.UsageRow] = []

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Derived usage data

    private var totalCost: Double {
        usageRows.reduce(0) { $0 + (cost(of: $1) ?? 0) }
    }

    private var monthCost: Double {
        let prefix = String(Self.dayParser.string(from: Date()).prefix(7))
        return usageRows.filter { $0.day.hasPrefix(prefix) }
            .reduce(0) { $0 + (cost(of: $1) ?? 0) }
    }

    private var totalInput: Int64 { usageRows.reduce(0) { $0 + $1.input + $1.cacheRead + $1.cacheWrite } }
    private var totalOutput: Int64 { usageRows.reduce(0) { $0 + $1.output } }

    private struct DayCost: Identifiable {
        var id: String { day }
        var day: String
        var date: Date
        var cost: Double
    }

    private var last30Days: [DayCost] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var byDay: [String: Double] = [:]
        for row in usageRows {
            byDay[row.day, default: 0] += cost(of: row) ?? 0
        }
        return byDay.compactMap { day, cost in
            guard let date = Self.dayParser.date(from: day), date >= cutoff else { return nil }
            return DayCost(day: day, date: date, cost: cost)
        }
        .sorted { $0.date < $1.date }
    }

    private struct ModelUsage: Identifiable {
        var id: String { model }
        var model: String
        var input: Int64
        var output: Int64
        var cost: Double?
    }

    private var byModel: [ModelUsage] {
        var agg: [String: (input: Int64, output: Int64, cost: Double, known: Bool)] = [:]
        for row in usageRows {
            var entry = agg[row.model] ?? (0, 0, 0, false)
            entry.input += row.input + row.cacheRead + row.cacheWrite
            entry.output += row.output
            if let c = cost(of: row) { entry.cost += c; entry.known = true }
            agg[row.model] = entry
        }
        return agg.map { model, entry in
            ModelUsage(model: model, input: entry.input, output: entry.output,
                       cost: entry.known ? entry.cost : nil)
        }
        .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
    }

    private func cost(of row: Database.UsageRow) -> Double? {
        Pricing.cost(model: row.model, input: row.input, output: row.output,
                     cacheRead: row.cacheRead, cacheWrite: row.cacheWrite)
    }

    // MARK: - Body

    var body: some View {
        let stats = state.stats
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Statistics").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Usage & cost
                    Text("Usage & estimated cost").font(.headline)
                    HStack(spacing: 16) {
                        statTile(value: Pricing.dollars(totalCost), label: "est. total (list price)")
                        statTile(value: Pricing.dollars(monthCost), label: "this month")
                        statTile(value: totalInput.tokenString, label: "input tokens (incl. cache)")
                        statTile(value: totalOutput.tokenString, label: "output tokens")
                    }

                    if usageRows.isEmpty {
                        Text("No usage data yet — the indexer is still processing transcripts. Check back in a minute.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !last30Days.isEmpty {
                        Chart(last30Days) { item in
                            BarMark(
                                x: .value("Day", item.date, unit: .day),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(Theme.accent(accentName))
                        }
                        .frame(height: 140)
                        .chartYAxisLabel("$ / day")
                    }

                    if !byModel.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                Text("Model").font(.caption).foregroundStyle(.secondary)
                                Text("Input").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text("Output").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text("Est. cost").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            }
                            ForEach(byModel) { m in
                                GridRow {
                                    Text(m.model).font(.system(.caption, design: .monospaced))
                                    Text(m.input.tokenString).foregroundStyle(.secondary)
                                    Text(m.output.tokenString).foregroundStyle(.secondary)
                                    Text(m.cost.map(Pricing.dollars) ?? "—").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.callout)
                    }

                    Text("Estimates at public list prices (cache writes 1.25×, cache reads 0.1× input). Subscription plans (Pro/Max) are flat-rate — treat this as usage insight, not a bill.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Divider()

                    // MARK: Disk & cleanup
                    Text("Sessions on disk").font(.headline)
                    HStack(spacing: 16) {
                        statTile(value: "\(stats.totalSessions)", label: "sessions")
                        statTile(value: stats.totalSize.byteString, label: "on disk (~/.claude/projects)")
                        statTile(value: "\(stats.projects.count)", label: "projects")
                    }

                    Text("Per project").font(.headline)
                    let maxSize = max(stats.projects.map(\.totalSize).max() ?? 1, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(stats.projects) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.name).lineLimit(1)
                                    Spacer()
                                    Text("\(p.sessionCount) sessions · \(p.totalSize.byteString)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Capsule()
                                    .fill(Theme.accent(accentName).opacity(0.45))
                                    .frame(width: max(6, CGFloat(p.totalSize) / CGFloat(maxSize) * 300), height: 5)
                            }
                            .help(p.key)
                        }
                    }
                    .font(.callout)

                    Text("Largest sessions").font(.headline)
                    VStack(spacing: 4) {
                        ForEach(stats.largest) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle).lineLimit(1)
                                    Text("\(session.projectName) · \(session.modifiedAt.relativeString)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(session.size.byteString)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Button {
                                    dismiss()
                                    state.selectedSessionId = session.id
                                    state.filter = .all
                                    state.searchText = ""
                                } label: {
                                    Image(systemName: "arrow.right.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Show in list")
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Text("Tip: delete or archive old sessions from their context menu in the list. Chatwerk removes the transcript together with its sidecar folders (file-history, tasks, subagents).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 700)
        .onAppear {
            usageRows = state.db.usageRows()
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 120, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
