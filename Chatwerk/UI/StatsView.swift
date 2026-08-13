import SwiftUI
import Charts

/// Usage & Stats sheet: a Usage tab (token cost analytics) and a Storage tab
/// (disk usage per project, largest sessions, cleanup).
struct StatsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"

    @State private var usageRows: [Database.UsageRow] = []
    @State private var tab: Tab = .usage
    @State private var hoveredSessionId: String?
    @State private var showAllProjects = false

    private enum Tab: Hashable {
        case usage, storage
    }

    private var accent: Color { Theme.accent(accentName) }

    /// usage_daily day keys are written from UTC timestamps, so every date
    /// derivation here uses the same UTC calendar to stay consistent.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

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
        costForMonth(offset: 0)
    }

    private var previousMonthCost: Double {
        costForMonth(offset: -1)
    }

    private func costForMonth(offset: Int) -> Double {
        guard let date = Self.utcCalendar.date(byAdding: .month, value: offset, to: Date()) else { return 0 }
        let prefix = String(Self.dayParser.string(from: date).prefix(7))
        return usageRows.filter { $0.day.hasPrefix(prefix) }
            .reduce(0) { $0 + (cost(of: $1) ?? 0) }
    }

    private var monthDelta: String? {
        guard previousMonthCost > 0, monthCost > 0 else { return nil }
        let pct = (monthCost - previousMonthCost) / previousMonthCost * 100
        guard let prev = Self.utcCalendar.date(byAdding: .month, value: -1, to: Date()) else { return nil }
        let name = prev.formatted(.dateTime.month(.abbreviated))
        return String(format: "%+.0f%% vs %@", pct, name)
    }

    private var totalInput: Int64 { usageRows.reduce(0) { $0 + $1.input + $1.cacheRead + $1.cacheWrite } }
    private var totalOutput: Int64 { usageRows.reduce(0) { $0 + $1.output } }

    private struct DayCost: Identifiable {
        var id: String { day }
        var day: String
        var date: Date
        var cost: Double
    }

    private var chartCutoff: Date {
        Self.utcCalendar.date(byAdding: .day, value: -29, to: Self.utcCalendar.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(-30 * 86_400)
    }

    private var last30Days: [DayCost] {
        let cutoff = chartCutoff
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

    private var averagePerDay: Double {
        last30Days.reduce(0) { $0 + $1.cost } / 30
    }

    private struct ModelUsage: Identifiable {
        var id: String { model }
        var model: String
        var displayName: String
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
            ModelUsage(model: model, displayName: Pricing.displayName(for: model),
                       input: entry.input, output: entry.output,
                       cost: entry.known ? entry.cost : nil)
        }
        .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
    }

    private func cost(of row: Database.UsageRow) -> Double? {
        Pricing.cost(model: row.model, input: row.input, output: row.output,
                     cacheRead: row.cacheRead, cacheWrite: row.cacheWrite,
                     cacheWrite1h: row.cacheWrite1h)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Usage & Stats").font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) {
                    Text("Usage").tag(Tab.usage)
                    Text("Storage").tag(Tab.storage)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .usage: usageTab
                    case .storage: storageTab
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 960,
               minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .task {
            usageRows = state.db.usageRows()
            // The indexer may still be backfilling — refresh until data shows up.
            while usageRows.isEmpty && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                usageRows = state.db.usageRows()
            }
        }
    }

    // MARK: - Usage tab

    @ViewBuilder
    private var usageTab: some View {
        if usageRows.isEmpty {
            ContentUnavailableView(
                "No usage data yet",
                systemImage: "chart.bar",
                description: Text("The indexer is still processing transcripts — this fills in automatically.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            HStack(spacing: 12) {
                statTile(value: Pricing.dollars(totalCost), label: "Est. total")
                statTile(value: Pricing.dollars(monthCost), label: "This month", caption: monthDelta)
                statTile(value: totalInput.tokenString, label: "Input tokens",
                         help: "Includes cache reads and writes")
                statTile(value: totalOutput.tokenString, label: "Output tokens")
            }

            card("Daily cost", subtitle: "Last 30 days") {
                Chart {
                    ForEach(last30Days) { item in
                        BarMark(
                            x: .value("Day", item.date, unit: .day),
                            y: .value("Cost", item.cost),
                            width: .ratio(0.55)
                        )
                        .foregroundStyle(
                            LinearGradient(colors: [accent, accent.opacity(0.65)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .cornerRadius(3)
                        .opacity(Self.utcCalendar.isDateInToday(item.date) ? 0.45 : 1)
                    }
                    if averagePerDay > 0 {
                        RuleMark(y: .value("Average", averagePerDay))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("avg \(Pricing.dollars(averagePerDay))/day")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .chartXScale(domain: chartCutoff...Date())
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine()
                        AxisValueLabel(format: .currency(code: "USD").precision(.fractionLength(0...2)))
                    }
                }
                .frame(height: 160)
            }

            card("By model") {
                Chart(byModel) { m in
                    BarMark(
                        x: .value("Cost", m.cost ?? 0),
                        y: .value("Model", m.displayName)
                    )
                    .foregroundStyle(accent)
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(m.cost.map(Pricing.dollars) ?? "—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .chartXScale(domain: 0...max((byModel.first?.cost ?? 1) * 1.22, 0.01))
                .frame(height: CGFloat(byModel.count) * 30 + 8)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(byModel) { m in
                        GridRow {
                            Text(m.displayName).font(.caption)
                            Text("\(m.input.tokenString) in")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text("\(m.output.tokenString) out")
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }

                Text("Estimated at public list prices — subscription plans (Pro/Max) are flat-rate, so treat this as usage insight, not a bill. Cache reads bill 0.1× input; cache writes 1.25× (5m TTL) / 2× (1h TTL). Includes subagent usage.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Storage tab

    @ViewBuilder
    private var storageTab: some View {
        let stats = state.stats
        HStack(spacing: 12) {
            statTile(value: "\(stats.totalSessions)", label: "Sessions")
            statTile(value: stats.totalSize.byteString, label: "On disk",
                     help: "~/.claude/projects")
            statTile(value: "\(stats.projects.count)", label: "Projects")
        }

        card("By project") {
            let ranked = stats.projects.sorted { $0.totalSize > $1.totalSize }
            let maxSize = max(ranked.first?.totalSize ?? 1, 1)
            let visible = showAllProjects ? ranked : Array(ranked.prefix(8))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(p.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(p.sessionCount) sessions · \(p.totalSize.byteString)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary.opacity(0.6))
                                Capsule().fill(accent)
                                    .frame(width: max(4, geo.size.width * CGFloat(p.totalSize) / CGFloat(maxSize)))
                            }
                        }
                        .frame(height: 5)
                    }
                    .help(p.key)
                }
                if ranked.count > 8 {
                    Button(showAllProjects ? "Show fewer" : "Show all \(ranked.count) projects") {
                        withAnimation { showAllProjects.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(accent)
                }
            }
        }

        card("Largest sessions") {
            VStack(spacing: 2) {
                ForEach(state.stats.largest) { session in
                    Button {
                        dismiss()
                        state.selectedSessionId = session.id
                        state.filter = .all
                        state.searchText = ""
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.displayTitle).lineLimit(1)
                                Text("\(session.projectName) · \(session.modifiedAt.relativeString)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(session.size.byteString)
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                                .opacity(hoveredSessionId == session.id ? 1 : 0)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(
                            hoveredSessionId == session.id ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredSessionId = hovering ? session.id : nil
                    }
                }
            }
            Text("Delete or archive old sessions from their context menu in the list. Chatwerk removes the transcript together with its sidecar folders (file-history, tasks, subagents).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Building blocks

    private func card(_ title: String, subtitle: String? = nil,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
    }

    private func statTile(value: String, label: String, caption: String? = nil, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .help(help ?? label)
    }
}
