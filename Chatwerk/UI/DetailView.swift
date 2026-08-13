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
    @State private var showNewTag = false
    @AppStorage("showInfoPanel") private var showInfoPanel = false
    @AppStorage("transcriptNewestFirst") private var newestFirst = true

    private var current: SessionInfo {
        state.sessions.first { $0.id == session.id } ?? session
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        transcriptSection(proxy: proxy)
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .inspector(isPresented: $showInfoPanel) {
            inspectorContent
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .onChange(of: session.id, initial: true) { _, _ in
            customTitle = session.customTitle ?? ""
            note = session.note ?? ""
        }
        .task(id: session.id) {
            transcript = nil
            loadingTranscript = true
            defer { loadingTranscript = false }
            let path = session.path
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
        .sheet(isPresented: $showNewTag) {
            NewTagSheet()
                .environmentObject(state)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    state.open(current)
                } label: {
                    Label("Continue in \(state.terminalKind.rawValue)", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Continue this session in your terminal (⌘↩)")

                Button {
                    showInfoPanel.toggle()
                } label: {
                    Label("Info", systemImage: "sidebar.trailing")
                }
                .help("Tags, notes & technical details")

                Menu {
                    Button {
                        state.copyCommand(current)
                    } label: {
                        Label("Copy Resume Command", systemImage: "doc.on.doc")
                    }
                    Button {
                        exportMarkdown()
                    } label: {
                        Label("Export as Markdown…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        archive()
                    } label: {
                        Label("Archive (zip)…", systemImage: "archivebox")
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = current
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Copy, export, archive, delete")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    state.toggleFavorite(current)
                } label: {
                    Image(systemName: current.favorite ? "star.fill" : "star")
                        .foregroundStyle(current.favorite ? .yellow : .secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Favorite")

                TextField(current.title ?? "Untitled session", text: $customTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { saveMeta() }
                    .onChange(of: customTitle) { _, _ in saveMeta() }

                if current.isWaitingForYou {
                    statusBadge("Your turn", icon: "hand.raised.fill", color: .orange)
                } else if current.isWorking {
                    statusBadge("Working…", icon: "dot.radiowaves.left.and.right", color: .green)
                }
                let daysLeft = state.daysUntilCleanup(for: current)
                if daysLeft <= 7 {
                    statusBadge(daysLeft <= 0 ? "Deleting soon" : "Deletes in \(daysLeft)d",
                                icon: "hourglass", color: daysLeft <= 3 ? .red : .orange)
                        .help("Claude Code auto-deletes idle transcripts after \(state.retentionDays) days (cleanupPeriodDays). Archive this session to keep a copy.")
                }
            }

            HStack(spacing: 6) {
                chip(icon: "folder", text: current.projectName, help: current.cwd ?? current.projectDir)
                chip(icon: "clock", text: current.modifiedAt.relativeString)
                chip(icon: "internaldrive", text: current.size.byteString)
                if current.messageCount > 0 {
                    chip(icon: "bubble.left.and.bubble.right", text: "\(current.messageCount) msgs")
                }
                ForEach(current.tags) { tag in
                    Text(tag.name)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tag.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(tag.color)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func chip(icon: String, text: String, help: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help(help ?? text)
    }

    // MARK: - Inspector (tags, notes, technical details)

    private var inspectorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tags", systemImage: "tag")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Tag this chat to find it again from the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    FlowLayoutLite(spacing: 6) {
                        ForEach(state.tags) { tag in
                            let isOn = current.tags.contains { $0.id == tag.id }
                            Button {
                                state.setTag(current, tag: tag, on: !isOn)
                            } label: {
                                HStack(spacing: 4) {
                                    if isOn {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                    Text(tag.name)
                                }
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(isOn ? tag.color.opacity(0.22) : Color.secondary.opacity(0.07), in: Capsule())
                                .overlay(Capsule().stroke(isOn ? tag.color : Color.secondary.opacity(0.25), lineWidth: 1))
                                .foregroundStyle(isOn ? tag.color : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            showNewTag = true
                        } label: {
                            Label("New", systemImage: "plus")
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.07), in: Capsule())
                                .overlay(Capsule().stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3])))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Note", systemImage: "note.text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("A reminder to future-you about what this chat was. Search looks in here too.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextEditor(text: $note)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 80, maxHeight: 160)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty {
                                Text("e.g. “Auth refactor — resume after the DB migration lands”")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: note) { _, _ in saveMeta() }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Technical details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    detailsGrid
                }

                Spacer()
            }
            .padding(14)
        }
    }

    private var detailsGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            infoRow("Project", current.cwd ?? current.projectDir)
            infoRow("Session", current.uuid, mono: true, copyable: true)
            if let created = current.createdAt {
                infoRow("Started", created.formatted(date: .abbreviated, time: .shortened))
            }
            infoRow("Last activity", current.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            infoRow("Auto-cleanup",
                    state.daysUntilCleanup(for: current) > 3650
                    ? "effectively never (cleanupPeriodDays: \(state.retentionDays))"
                    : "in \(max(state.daysUntilCleanup(for: current), 0)) days (cleanupPeriodDays: \(state.retentionDays))")
            if let model = current.model {
                infoRow("Model", model, mono: true)
            }
            if let branch = current.gitBranch, !branch.isEmpty {
                infoRow("Branch", branch, mono: true)
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String, mono: Bool = false, copyable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Text(value)
                    .font(mono ? .system(.caption, design: .monospaced) : .caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if copyable {
                    Button {
                        state.copyCommand(current)
                    } label: {
                        Image(systemName: "doc.on.doc").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Copy resume command")
                }
            }
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private func transcriptSection(proxy: ScrollViewProxy) -> some View {
        HStack {
            Label("Transcript", systemImage: "text.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let t = transcript {
                Text(t.truncatedHead
                     ? "last \(t.entries.count) entries"
                     : "\(t.totalEntries) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    newestFirst.toggle()
                } label: {
                    Label(newestFirst ? "Newest first" : "Oldest first",
                          systemImage: "arrow.up.arrow.down")
                }
                .controlSize(.small)
                .help("Flip transcript order")
                if !newestFirst {
                    Button {
                        withAnimation { proxy.scrollTo("transcript-end", anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down.to.line")
                    }
                    .controlSize(.small)
                    .help("Jump to the end of the conversation")
                }
            }
        }

        if loadingTranscript {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading transcript…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        } else if let t = transcript {
            let ordered = newestFirst ? Array(t.entries.reversed()) : t.entries
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(groupedItems(ordered)) { item in
                    switch item {
                    case .message(let entry):
                        TranscriptEntryView(entry: entry)
                    case .toolRun(let entries):
                        ToolRunView(entries: entries)
                    }
                }
            }
        }
    }

    /// Consecutive tool/thinking entries collapse into one "N background steps"
    /// row so the conversation isn't drowned in tool noise.
    private enum TranscriptItem: Identifiable {
        case message(TranscriptEntry)
        case toolRun([TranscriptEntry])
        var id: Int {
            switch self {
            case .message(let e): return e.id
            case .toolRun(let list): return -(list[0].id + 1_000_000)
            }
        }
    }

    private func groupedItems(_ entries: [TranscriptEntry]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var run: [TranscriptEntry] = []
        func flush() {
            if run.count == 1 { out.append(.message(run[0])) }
            else if run.count > 1 { out.append(.toolRun(run)) }
            run = []
        }
        for e in entries {
            switch e.kind {
            case .user, .assistant:
                flush()
                out.append(.message(e))
            default:
                run.append(e)
            }
        }
        flush()
        return out
    }

    // MARK: - Actions

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

// MARK: - Transcript entries

struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    @AppStorage("accentName") private var accentName2: String = "Sewerk Orange"
    @State private var expanded = false

    private var accent: Color { Theme.accent(accentName2) }

    var body: some View {
        switch entry.kind {
        case .user, .assistant:
            let isUser = entry.kind == .user
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    RoleAvatar(isUser: isUser, accent: accent, size: 20)
                    Text(entry.roleLabel)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isUser ? accent : .primary)
                    if let ts = entry.timestamp {
                        Text(ts.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                MessageBody(text: entry.text.count > 6000 ? String(entry.text.prefix(6000)) + " …" : entry.text)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.leading, 27)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isUser ? accent.opacity(0.13) : Color.secondary.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isUser ? accent.opacity(0.35) : Color.secondary.opacity(0.2))
            )
        case .thinking, .toolUse, .toolResult:
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView(.horizontal) {
                    Text(entry.text.prefix(8000))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Label(entry.roleLabel, systemImage: iconName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 14)
        }
    }

    private var iconName: String {
        switch entry.kind {
        case .thinking: return "brain"
        case .toolUse: return "wrench.and.screwdriver"
        case .toolResult: return "arrow.turn.down.left"
        default: return "circle"
        }
    }
}

/// A collapsed run of consecutive tool/thinking entries.
struct ToolRunView: View {
    let entries: [TranscriptEntry]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    TranscriptEntryView(entry: entry)
                }
            }
            .padding(.leading, 6)
        } label: {
            Label("\(entries.count) background steps", systemImage: "gearshape.2")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 14)
    }
}

/// Small round avatar: person for the user, sparkles for Claude.
struct RoleAvatar: View {
    let isUser: Bool
    let accent: Color
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(isUser ? accent : Color(hex: "#D97757") ?? .orange)
            Image(systemName: isUser ? "person.fill" : "sparkles")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Renders message text readably: fenced ``` code blocks become monospaced
/// boxes, everything else gets inline-markdown styling (bold, italics,
/// `code`) with comfortable line spacing.
struct MessageBody: View {
    let text: String

    private struct Segment: Identifiable {
        let id: Int
        let isCode: Bool
        let text: String
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        let parts = text.components(separatedBy: "```")
        for (i, raw) in parts.enumerated() {
            let isCode = i % 2 == 1
            var body = raw
            if isCode {
                // Drop a leading language hint like "swift\n".
                if let nl = body.firstIndex(of: "\n"),
                   body[body.startIndex..<nl].allSatisfy({ !$0.isWhitespace }) {
                    body = String(body[body.index(after: nl)...])
                }
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(Segment(id: i, isCode: isCode, text: trimmed))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                if segment.isCode {
                    ScrollView(.horizontal) {
                        Text(segment.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    Text(Self.inlineMarkdown(segment.text))
                        .font(.body)
                        .lineSpacing(3.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private static func inlineMarkdown(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(s)
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
