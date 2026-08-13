import SwiftUI
import AppKit

/// Hands the hosting NSWindow to AppState so notification clicks can re-front it.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { AppState.shared?.mainWindow = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { AppState.shared?.mainWindow = window }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var pendingDelete: SessionInfo?
    @State private var showStats = false
    @State private var showNewTag = false
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showNewTag: $showNewTag)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            SessionListView(pendingDelete: $pendingDelete)
                .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            if let session = state.selectedSession {
                // NOTE: no .id(session.id) here — forcing a full DetailView
                // (and unified-toolbar) teardown per selection is visibly slow.
                DetailView(session: session, pendingDelete: $pendingDelete)
            } else {
                ContentUnavailableView("Select a session",
                                       systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Pick a Claude Code session to preview, tag or resume it."))
            }
        }
        .searchable(text: $state.searchText, placement: .toolbar,
                    prompt: "Search sessions…")
        .onChange(of: state.searchText) { _, _ in state.searchTextChanged() }
        .toolbar {
            ToolbarItem {
                if let progress = state.indexProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Indexing \(progress.done)/\(progress.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem {
                Button {
                    showStats = true
                } label: {
                    Label("Usage & Stats", systemImage: "chart.bar.xaxis")
                }
                .help("Token usage, costs & cleanup")
            }
        }
        .sheet(isPresented: $showStats) {
            StatsView()
                .environmentObject(state)
        }
        .sheet(isPresented: Binding(
            get: { !didOnboard && !state.claudeDirMissing },
            set: { if !$0 { didOnboard = true } }
        )) {
            OnboardingView()
                .environmentObject(state)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showNewTag) {
            NewTagSheet()
                .environmentObject(state)
        }
        .alert("Chatwerk", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.alertMessage ?? "")
        }
        .confirmationDialog(
            "Delete this session permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { session in
            Button("Delete \"\(String(session.displayTitle.prefix(40)))\"", role: .destructive) {
                state.delete(session)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { session in
            let items = Cleaner.previewPaths(session: session)
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            Text("Removes the transcript and all sidecar data (\(items.count) items, \(total.byteString)) from ~/.claude. This cannot be undone.")
        }
        .overlay {
            if state.claudeDirMissing {
                ContentUnavailableView(
                    "No Claude Code data found",
                    systemImage: "questionmark.folder",
                    description: Text("Chatwerk reads sessions from ~/.claude/projects. Install and use Claude Code first — then relaunch Chatwerk.")
                )
                .background(.background)
            }
        }
        .overlay(alignment: .top) {
            if state.showQuickSearch {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                        .onTapGesture { state.showQuickSearch = false }
                    QuickSearchView()
                        .environmentObject(state)
                        .padding(.top, 90)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: state.showQuickSearch)
        .background(WindowAccessor())
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Binding var showNewTag: Bool

    var body: some View {
        List(selection: Binding(
            get: { Optional(state.filter) },
            set: { state.filter = $0 ?? .all }
        )) {
            Section("Library") {
                Label("All Sessions", systemImage: "bubble.left.and.bubble.right")
                    .badge(state.sessions.count)
                    .tag(SidebarFilter.all)
                Label("Favorites", systemImage: "star.fill")
                    .badge(state.sessions.filter(\.favorite).count)
                    .tag(SidebarFilter.favorites)
                Label { Text("Running Now") } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                }
                .badge(state.sessions.filter(\.isLive).count)
                .tag(SidebarFilter.live)
                Label("Unsorted", systemImage: "tag.slash")
                    .badge(state.sessions.filter(\.isUnsorted).count)
                    .tag(SidebarFilter.unsorted)
                if state.expiringCount > 0 {
                    Label { Text("Expiring Soon") } icon: {
                        Image(systemName: "hourglass").foregroundStyle(.red)
                    }
                    .badge(state.expiringCount)
                    .tag(SidebarFilter.expiring)
                    .help("Claude Code auto-deletes transcripts after \(state.retentionDays) days of inactivity (cleanupPeriodDays)")
                }
            }
            Section("Projects") {
                ForEach(state.projectGroups) { group in
                    Label(group.name, systemImage: "folder.fill")
                        .badge(group.sessionCount)
                        .tag(SidebarFilter.project(group.key))
                        .help(group.key)
                }
            }
            Section("Tags") {
                ForEach(state.tags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Circle().fill(tag.color).frame(width: 10, height: 10)
                    }
                    .tag(SidebarFilter.tag(tag.id))
                    .contextMenu {
                        Button("Delete Tag", role: .destructive) { state.deleteTag(tag) }
                    }
                }
                Button {
                    showNewTag = true
                } label: {
                    Label("New Tag…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 9) {
                    Image("SewerkMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Chatwerk")
                            .font(.caption.weight(.semibold))
                        Text("by Sewerk · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .background(.bar)
        }
    }
}

// MARK: - Session list

struct SessionListView: View {
    @EnvironmentObject var state: AppState
    @Binding var pendingDelete: SessionInfo?

    var body: some View {
        List(selection: $state.selectedSessionId) {
            if state.searchResults != nil {
                // Search results stay flat: ordered by relevance, not date.
                ForEach(state.visibleSessions) { session in
                    SessionRowView(session: session, pendingDelete: $pendingDelete)
                        .tag(session.id)
                        .listRowBackground(rowBackground(for: session))
                }
            } else {
                ForEach(groupedSessions, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.items) { session in
                            SessionRowView(session: session, pendingDelete: $pendingDelete)
                                .tag(session.id)
                                .listRowBackground(rowBackground(for: session))
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        // Native List double-click (primaryAction) + selection-based context
        // menu: row-level tap gestures delay single-click selection on macOS.
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first,
               let session = state.sessions.first(where: { $0.id == id }) {
                menuItems(for: session)
            }
        } primaryAction: { ids in
            if let id = ids.first,
               let session = state.sessions.first(where: { $0.id == id }) {
                state.open(session)
            }
        }
        .overlay {
            if state.visibleSessions.isEmpty && !state.claudeDirMissing {
                if state.searchResults != nil {
                    ContentUnavailableView.search(text: state.searchText)
                } else {
                    emptyState
                }
            }
        }
        .navigationTitle(navigationTitle)
    }

    /// Empty states explain the next step instead of a bare "nothing here".
    @ViewBuilder
    private var emptyState: some View {
        switch state.filter {
        case .favorites:
            ContentUnavailableView("No Favorites yet", systemImage: "star",
                                   description: Text("Right-click a session and choose Add to Favorites."))
        case .live:
            ContentUnavailableView("Nothing running", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("No Claude Code session is active right now."))
        case .unsorted:
            ContentUnavailableView("All sorted", systemImage: "tag",
                                   description: Text("Every session has a tag, note or custom title."))
        case .expiring:
            ContentUnavailableView("Nothing expiring", systemImage: "hourglass",
                                   description: Text("No session is close to Claude Code's auto-cleanup."))
        case .tag:
            ContentUnavailableView("No sessions with this tag", systemImage: "tag",
                                   description: Text("Right-click sessions to apply this tag."))
        default:
            ContentUnavailableView("No sessions here", systemImage: "tray")
        }
    }

    @ViewBuilder
    private func menuItems(for session: SessionInfo) -> some View {
        Button("Continue in \(state.terminalKind.rawValue)") { state.open(session) }
        Button("Copy Resume Command") { state.copyCommand(session) }
        Divider()
        Button(session.favorite ? "Remove from Favorites" : "Add to Favorites") {
            state.toggleFavorite(session)
        }
        if !state.tags.isEmpty {
            Menu("Tags") {
                ForEach(state.tags) { tag in
                    let isOn = session.tags.contains { $0.id == tag.id }
                    Button {
                        state.setTag(session, tag: tag, on: !isOn)
                    } label: {
                        HStack {
                            if isOn { Image(systemName: "checkmark") }
                            Text(tag.name)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = session }
    }

    /// Attention tint: orange = Claude answered and waits for you,
    /// faint green = Claude is still working. Selection highlight stays intact.
    private func rowBackground(for session: SessionInfo) -> Color? {
        guard session.id != state.selectedSessionId else { return nil }
        if session.isWaitingForYou { return Theme.waitingRowTint }
        if session.isWorking { return Theme.workingRowTint }
        return nil
    }

    /// Time buckets so scanning by memory ("it was last week…") works.
    /// Boundary dates are computed once; per-session work is plain comparisons
    /// (Calendar component math per row made every render noticeably slow).
    private var groupedSessions: [(label: String, items: [SessionInfo])] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfMonth = cal.dateInterval(of: .month, for: now)?.start ?? startOfToday

        var buckets: [(label: String, items: [SessionInfo])] = [
            ("Today", []), ("Yesterday", []), ("This Week", []), ("This Month", []), ("Older", []),
        ]
        for s in state.visibleSessions {
            let d = s.modifiedAt
            let idx: Int
            if d >= startOfToday { idx = 0 }
            else if d >= startOfYesterday { idx = 1 }
            else if d >= startOfWeek { idx = 2 }
            else if d >= startOfMonth { idx = 3 }
            else { idx = 4 }
            buckets[idx].items.append(s)
        }
        return buckets.filter { !$0.items.isEmpty }
    }

    private var navigationTitle: String {
        if state.searchResults != nil { return "Search results" }
        switch state.filter {
        case .all: return "All Sessions"
        case .favorites: return "Favorites"
        case .live: return "Running Now"
        case .unsorted: return "Unsorted"
        case .expiring: return "Expiring Soon"
        case .project(let key): return state.projectGroups.first { $0.key == key }?.name ?? "Project"
        case .tag(let id): return state.tags.first { $0.id == id }?.name ?? "Tag"
        }
    }
}

struct SessionRowView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"
    let session: SessionInfo
    @Binding var pendingDelete: SessionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if session.isWaitingForYou {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                        .help("Claude answered — waiting for you")
                } else if session.isWorking {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .help("Claude is working right now")
                }
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                let daysLeft = state.daysUntilCleanup(for: session)
                if daysLeft <= 7 {
                    Label(daysLeft <= 0 ? "Deleting soon" : "\(daysLeft)d left", systemImage: "hourglass")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(daysLeft <= 3 ? .red : .orange)
                        .help("Claude Code auto-deletes idle transcripts after \(state.retentionDays) days. Archive it (right-click) to keep a copy.")
                }
                if session.favorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .imageScale(.small)
                }
            }
            Text("\(session.projectName) · \(metaLine)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !session.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(session.tags) { tag in
                        Text(tag.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(tag.color.opacity(0.2), in: Capsule())
                            .foregroundStyle(tag.color)
                    }
                }
            }
            if let snippet = session.searchSnippet {
                Text(SnippetText.highlighted(snippet, accent: Theme.accent(accentName)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let last = session.lastPrompt, !last.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("Last thing you asked in this session")
            }
        }
        .padding(.vertical, 4)
    }

    private var metaLine: String {
        var parts = [session.modifiedAt.relativeString, session.size.byteString]
        if session.messageCount > 0 { parts.append("\(session.messageCount) messages") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - New tag sheet

struct NewTagSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = Color(hex: "#7B61FF") ?? .purple

    private static let palette = ["#7B61FF", "#FF6B6B", "#FFA94D", "#40C057", "#339AF0", "#F06595", "#845EF7", "#20C997"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag").font(.title3.bold())
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack(spacing: 8) {
                ForEach(Self.palette, id: \.self) { hex in
                    let c = Color(hex: hex) ?? .purple
                    Circle()
                        .fill(c)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if c == color { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) }
                        }
                        .onTapGesture { color = c }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let hex = Self.palette.first { Color(hex: $0) == color } ?? "#7B61FF"
                    state.createTag(name: name, colorHex: hex)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
