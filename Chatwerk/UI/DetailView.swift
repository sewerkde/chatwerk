import SwiftUI
import AppKit

struct DetailView: View {
    @EnvironmentObject var state: AppState
    let session: SessionInfo
    @Binding var pendingDelete: SessionInfo?
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"
    private var accent: Color { Theme.accent(accentName) }

    @State private var customTitle: String = ""
    @State private var note: String = ""
    @State private var transcript: TranscriptPage?
    @State private var loadingTranscript = false

    private var current: SessionInfo {
        state.sessions.first { $0.id == session.id } ?? session
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        whereYouLeftOff
                        metadata
                        tagsEditor
                        noteEditor
                        Divider()
                        transcriptSection(proxy: proxy)
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: session.id, initial: true) { _, _ in
            // The view persists across selections (no .id teardown), so local
            // editor state resets here instead of in init.
            customTitle = session.customTitle ?? ""
            note = session.note ?? ""
        }
        .task(id: session.id) {
            transcript = nil
            loadingTranscript = true
            defer { loadingTranscript = false }
            let path = session.path
            // Detached so parsing never touches the main thread; cancellation is
            // forwarded so switching sessions kills the previous read immediately.
            let job = Task.detached(priority: .userInitiated) {
                TranscriptLoader.load(path: path)
            }
            let page = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            if !Task.isCancelled {
                transcript = page
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.open(current)
                } label: {
                    Label("Continue in \(state.terminalKind.rawValue)", systemImage: "play.fill")
                }
                .help("Continue this session in your terminal")

                Button {
                    state.copyCommand(current)
                } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
                .help("Copy `claude --resume` command")

                Button {
                    exportMarkdown()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export transcript as Markdown")

                Button {
                    archive()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .help("Zip this session's files")

                Button(role: .destructive) {
                    pendingDelete = current
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    state.toggleFavorite(current)
                } label: {
                    Image(systemName: current.favorite ? "star.fill" : "star")
                        .foregroundStyle(current.favorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Favorite")

                TextField(current.title ?? "Untitled session", text: $customTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { saveMeta() }
                    .onChange(of: customTitle) { _, _ in saveMeta() }

                if current.isWaitingForYou {
                    Label("Waiting for you", systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if current.isWorking {
                    Label("Working…", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            if !customTitle.isEmpty, let auto = current.title {
                Text(auto)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Project").foregroundStyle(.secondary)
                Text(current.cwd ?? current.projectDir)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            GridRow {
                Text("Session").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(current.uuid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button {
                        state.copyCommand(current)
                    } label: {
                        Image(systemName: "doc.on.doc").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Copy resume command")
                }
            }
            GridRow {
                Text("Last activity").foregroundStyle(.secondary)
                Text(current.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let created = current.createdAt {
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Text(created.formatted(date: .abbreviated, time: .shortened))
                }
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text("\(current.size.byteString)\(current.messageCount > 0 ? "  ·  \(current.messageCount) messages" : "")")
            }
            if let model = current.model {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(model).font(.system(.caption, design: .monospaced))
                }
            }
            if let branch = current.gitBranch, !branch.isEmpty {
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text(branch).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .font(.callout)
    }

    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            if state.tags.isEmpty {
                Text("No tags yet — create one from the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayoutLite(spacing: 6) {
                    ForEach(state.tags) { tag in
                        let isOn = current.tags.contains { $0.id == tag.id }
                        Button {
                            state.setTag(current, tag: tag, on: !isOn)
                        } label: {
                            Text(tag.name)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isOn ? tag.color.opacity(0.25) : Color.secondary.opacity(0.08), in: Capsule())
                                .overlay(Capsule().stroke(isOn ? tag.color : Color.secondary.opacity(0.3), lineWidth: 1))
                                .foregroundStyle(isOn ? tag.color : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $note)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .onChange(of: note) { _, _ in saveMeta() }
        }
    }

    /// The core "I forgot where I was" feature: last question + Claude's last
    /// answer, with a resume button — visible before anything else.
    @ViewBuilder
    private var whereYouLeftOff: some View {
        if let t = transcript,
           let lastAnswer = t.entries.last(where: { $0.kind == .assistant }) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Where you left off", systemImage: "clock.arrow.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let lastPrompt = current.lastPrompt, !lastPrompt.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text("You:").font(.callout.bold()).foregroundStyle(accent)
                        Text(lastPrompt).font(.callout).lineLimit(3).textSelection(.enabled)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text("Claude:").font(.callout.bold()).foregroundStyle(.secondary)
                    Text(String(lastAnswer.text.prefix(700)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                Button {
                    state.open(current)
                } label: {
                    Label("Continue in \(state.terminalKind.rawValue)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.2)))
        }
    }

    @ViewBuilder
    private func transcriptSection(proxy: ScrollViewProxy) -> some View {
        HStack {
            Text("Transcript").font(.headline)
            Spacer()
            if let t = transcript {
                Text(t.truncatedHead
                     ? "last \(t.entries.count) entries"
                     : "\(t.totalEntries) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation { proxy.scrollTo("transcript-end", anchor: .bottom) }
                } label: {
                    Label("Latest", systemImage: "arrow.down.to.line")
                }
                .controlSize(.small)
                .help("Jump to the end of the conversation")
            }
        }
        if loadingTranscript {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading transcript… (large sessions take a few seconds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let t = transcript {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(t.entries) { entry in
                    TranscriptEntryView(entry: entry)
                }
            }
        }
    }

    private func saveMeta() {
        let title = customTitle.isEmpty ? nil : customTitle
        let noteValue = note.isEmpty ? nil : note
        // Skip no-op writes — the per-selection state reset would otherwise
        // publish a fake change on every click.
        guard title != current.customTitle || noteValue != current.note else { return }
        state.updateMeta(current, customTitle: customTitle, note: note, favorite: current.favorite)
    }

    private func exportMarkdown() {
        guard let page = transcript else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(current.displayTitle.prefix(40)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let md = TranscriptLoader.exportMarkdown(session: current, page: page)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.alertMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func archive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Archive Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.archive(current, to: url)
    }
}

struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    @AppStorage("accentName") private var accentName2: String = "Sewerk Orange"
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.roleLabel)
                        .font(.caption.bold())
                        .foregroundStyle(entry.kind == .user ? Theme.accent(accentName2) : .secondary)
                    if let ts = entry.timestamp {
                        Text(ts.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                entry.kind == .user ? Theme.accent(accentName2).opacity(0.08) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
        case .thinking, .toolUse, .toolResult:
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView(.horizontal) {
                    Text(entry.text.prefix(8000))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                }
            } label: {
                Text(entry.roleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        }
    }
}

/// Minimal wrapping layout for tag chips.
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
