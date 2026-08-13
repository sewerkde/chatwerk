import SwiftUI

struct StatsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stats = state.stats
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Statistics & Cleanup").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 24) {
                        statTile(value: "\(stats.totalSessions)", label: "sessions")
                        statTile(value: stats.totalSize.byteString, label: "on disk (~/.claude/projects)")
                        statTile(value: "\(stats.projects.count)", label: "projects")
                    }

                    Text("Per project").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        ForEach(stats.projects) { p in
                            GridRow {
                                Text(p.name).lineLimit(1)
                                Text("\(p.sessionCount)").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(p.totalSize.byteString).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
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
        .frame(width: 560, height: 620)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 130, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
