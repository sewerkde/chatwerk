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
                    VStack(alignment: .leading, spacing: 14) {
                        whereYouLeftOff
                        detailsCard
                        organizeCard
                        transcriptSection(proxy: proxy)
                        Color.clear.frame(height: 1).id("transcript-end")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
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
            }

            HStack(spacing: 6) {
                chip(icon: "folder", text: current.projectName, help: current.cwd ?? current.projectDir)
                chip(icon: "clock", text: current.modifiedAt.relativeString)
                chip(icon: "internaldrive", text: current.size.byteString)
                if current.messageCount > 0 {
                    chip(icon: "bubble.left.and.bubble.right", text: "\(current.messageCount) msgs")
                }
                if !customTitle.isEmpty, let auto = current.title {
                    Text(auto)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, 4)
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

    // MARK: - Cards

    private func card<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }

    /// The core "I forgot where I was" feature: last question + Claude's last
    /// answer, with a resume button — visible before anything else.
    @ViewBuilder
    private var whereYouLeftOff: some View {
        if let t = transcript,
           let lastAnswer = t.entries.last(where: { $0.kind == .assistant }) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Where you left off", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                if let lastPrompt = current.lastPrompt, !lastPrompt.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("You")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)
                            .frame(width: 48, alignment: .trailing)
                        Text(TranscriptLoader.plainPreview(lastPrompt, maxLength: 240))
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Claude")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    Text(TranscriptLoader.plainPreview(lastAnswer.text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                Button {
                    state.open(current)
                } label: {
                    Label("Continue in \(state.terminalKind.rawValue)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.leading, 58)
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
    }

    private var detailsCard: some View {
        card("Details", icon: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Project").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(current.cwd ?? current.projectDir)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                GridRow {
                    Text("Session").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(current.uuid)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            state.copyCommand(current)
                        } label: {
                            Image(systemName: "doc.on.doc").imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Copy resume command")
                    }
                }
                if let created = current.createdAt {
                    GridRow {
                        Text("Started").foregroundStyle(.secondary)
                        Text(created.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                GridRow {
                    Text("Last activity").foregroundStyle(.secondary)
                    Text(current.modifiedAt.formatted(date: .abbreviated, time: .shortened))
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
    }

    private var organizeCard: some View {
        card("Tags & Notes", icon: "tag") {
            VStack(alignment: .leading, spacing: 10) {
                if state.tags.isEmpty {
                    Text("No tags yet — create one from the sidebar to group related chats.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
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
                    }
                }
                TextEditor(text: $note)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 54, maxHeight: 110)
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("Add a note so future-you remembers what this chat was about…")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: note) { _, _ in saveMeta() }
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
                    withAnimation { proxy.scrollTo("transcript-end", anchor: .bottom) }
                } label: {
                    Label("Latest", systemImage: "arrow.down.to.line")
                }
                .controlSize(.small)
                .help("Jump to the end of the conversation")
            }
        }
        .padding(.top, 6)

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
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(t.entries) { entry in
                    TranscriptEntryView(entry: entry)
                }
            }
        }
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isUser ? accent : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(entry.roleLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isUser ? accent : .secondary)
                    if let ts = entry.timestamp {
                        Text(ts.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                MessageBody(text: entry.text.count > 6000 ? String(entry.text.prefix(6000)) + " …" : entry.text)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isUser ? accent.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isUser ? accent.opacity(0.2) : Color.secondary.opacity(0.12))
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
