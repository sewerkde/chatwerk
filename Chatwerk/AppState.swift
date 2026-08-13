import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    @Published var sessions: [SessionInfo] = []
    @Published var tags: [TagInfo] = []
    @Published var filter: SidebarFilter = .all
    @Published var searchText: String = ""
    @Published var searchResults: [SessionInfo]? = nil     // nil = not searching
    @Published var indexProgress: (done: Int, total: Int)? = nil
    @Published var liveIds: Set<String> = []
    @Published var claudeDirMissing = false
    @Published var alertMessage: String? = nil
    @Published var selectedSessionId: String? = nil

    let db: Database
    private var indexer: Indexer?
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastScanSignature: String = ""

    // Settings
    @AppStorage("terminalKind") var terminalKindRaw: String = TerminalKind.terminal.rawValue
    @AppStorage("claudeCommand") var claudeCommand: String = "claude"
    @AppStorage("showMenuBarExtra") var showMenuBarExtra: Bool = true
    /// true → double-click/Enter continues the session inside Chatwerk;
    /// false → hands off to the external terminal app.
    @AppStorage("openInApp") var openInAppDefault: Bool = true
    /// Alert when a running session finishes responding (busy → idle).
    @AppStorage("notifyWhenReady") var notifyWhenReady: Bool = true
    @AppStorage("notifyWithBanner") var notifyWithBanner: Bool = true
    @AppStorage("notifyWithSound") var notifyWithSound: Bool = true
    @AppStorage("readySound") var readySound: String = "Glass"

    var terminalKind: TerminalKind {
        TerminalKind(rawValue: terminalKindRaw) ?? .terminal
    }

    init() {
        do {
            db = try Database(url: ClaudePaths.databaseURL)
        } catch {
            fatalError("Chatwerk could not open its database: \(error)")
        }
        claudeDirMissing = !ClaudePaths.exists
        sessions = Self.deduped(db.loadAllSessions())
        tags = db.allTags()
        refreshLive()
        startBackgroundWork()
        if notifyWhenReady, notifyWithBanner {
            Notifier.requestAuthorizationIfNeeded()
        }
    }

    // MARK: - Visible list

    var visibleSessions: [SessionInfo] {
        var base = searchResults ?? sessions
        if searchResults == nil {
            switch filter {
            case .all: break
            case .favorites: base = base.filter { $0.favorite }
            case .live: base = base.filter { $0.isLive }
            case .unsorted: base = base.filter { $0.isUnsorted }
            case .project(let key): base = base.filter { ($0.cwd ?? $0.projectDir) == key }
            case .tag(let id): base = base.filter { s in s.tags.contains { $0.id == id } }
            }
        }
        return base
    }

    var projectGroups: [ProjectGroup] {
        var byKey: [String: (name: String, count: Int, size: Int64)] = [:]
        for s in sessions {
            let key = s.cwd ?? s.projectDir
            var entry = byKey[key] ?? (name: s.projectName, count: 0, size: 0)
            entry.count += 1
            entry.size += s.size
            byKey[key] = entry
        }
        return byKey.map { ProjectGroup(key: $0.key, name: $0.value.name, sessionCount: $0.value.count, totalSize: $0.value.size) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedSession: SessionInfo? {
        visibleSessions.first { $0.id == selectedSessionId } ?? sessions.first { $0.id == selectedSessionId }
    }

    // MARK: - Background scan / index / live poll

    private func startBackgroundWork() {
        guard !claudeDirMissing else { return }
        rescanAndReload(fullIndex: true)

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                self.refreshLive()
                await self.rescanIfChanged()
            }
        }
    }

    /// Cheap change signature: file count + newest mtime + total size.
    private nonisolated static func scanSignature() -> String {
        let fm = FileManager.default
        var count = 0
        var newest: TimeInterval = 0
        var total: Int64 = 0
        if let dirs = try? fm.contentsOfDirectory(at: ClaudePaths.projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in dirs {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for f in files where f.pathExtension == "jsonl" {
                    guard let rv = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                    count += 1
                    total += Int64(rv.fileSize ?? 0)
                    newest = max(newest, rv.contentModificationDate?.timeIntervalSince1970 ?? 0)
                }
            }
        }
        return "\(count)|\(newest)|\(total)"
    }

    private func rescanIfChanged() async {
        let sig = await Task.detached(priority: .utility) { Self.scanSignature() }.value
        if sig != lastScanSignature {
            lastScanSignature = sig
            rescanAndReload(fullIndex: true)
        }
    }

    private func rescanAndReload(fullIndex: Bool) {
        let database = db
        Task.detached(priority: .utility) { [weak self] in
            let scanner = SessionScanner(db: database)
            scanner.statScan()
            scanner.refreshDetails()
            let loaded = Self.deduped(database.loadAllSessions())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessions = loaded
                self.applyLiveBadges()
            }
            if fullIndex {
                await self?.runIndexer()
            }
        }
    }

    private func runIndexer() async {
        let database = db
        let indexer = Indexer(db: database)
        self.indexer?.cancel()
        self.indexer = indexer
        indexer.progress = { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.indexProgress = done >= total ? nil : (done, total)
            }
        }
        await Task.detached(priority: .background) {
            indexer.runOnce()
        }.value
        indexProgress = nil
        // New content may satisfy the current search.
        if !searchText.isEmpty { performSearch() }
    }

    /// Last seen status per live session ("busy", "idle", …) for ready-alerts.
    private var lastLiveStatus: [String: String] = [:]
    /// Current status per live session, applied to rows as `liveStatus`.
    private var liveStatusById: [String: String] = [:]

    private func refreshLive() {
        let live = LiveSessions.current()
        let ids = Set(live.keys)
        if ids != liveIds { liveIds = ids }
        liveStatusById = live.compactMapValues { $0.status }
        applyLiveBadges()

        // Alert when a session we've previously seen busy becomes idle again:
        // Claude finished responding and is waiting for the user.
        if notifyWhenReady {
            for (sessionId, info) in live {
                let status = info.status ?? "unknown"
                if let previous = lastLiveStatus[sessionId],
                   previous != "idle", status == "idle" {
                    let title = sessions.first { $0.uuid == sessionId }?.displayTitle ?? "Claude Code session"
                    Notifier.claudeIsReady(sessionTitle: title,
                                           soundName: notifyWithSound ? readySound : nil,
                                           showBanner: notifyWithBanner)
                }
            }
        }
        lastLiveStatus = live.mapValues { $0.status ?? "unknown" }
    }

    private func applyLiveBadges() {
        for i in sessions.indices {
            let isLive = liveIds.contains(sessions[i].uuid)
            let status = liveStatusById[sessions[i].uuid]
            if sessions[i].isLive != isLive { sessions[i].isLive = isLive }
            if sessions[i].liveStatus != status { sessions[i].liveStatus = status }
        }
    }

    /// The same session uuid can appear under several project dirs (cd mid-session);
    /// keep the largest transcript as the canonical row.
    private nonisolated static func deduped(_ rows: [SessionInfo]) -> [SessionInfo] {
        var best: [String: SessionInfo] = [:]
        for row in rows {
            if let existing = best[row.uuid], existing.size >= row.size { continue }
            best[row.uuid] = row
        }
        return best.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Search

    func searchTextChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.performSearch()
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = nil; return }
        let database = db
        let all = sessions
        Task.detached(priority: .userInitiated) { [weak self] in
            let final = Self.computeSearch(db: database, all: all, query: query)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                self.searchResults = final
            }
        }
    }

    /// Shared search core: FTS content hits + title/note/tag/uuid matches.
    /// Meta matches rank first (a title hit beats a body hit), then recency.
    nonisolated static func computeSearch(db: Database, all: [SessionInfo], query: String) -> [SessionInfo] {
        let hits = db.searchContent(query)
        let snippetByUuid = Dictionary(uniqueKeysWithValues: hits.map { ($0.uuid, $0.snippet) })
        let lower = query.lowercased()

        var metaMatches: [SessionInfo] = []
        var contentMatches: [SessionInfo] = []
        for var s in all {
            let inMeta = s.displayTitle.lowercased().contains(lower)
                || (s.note?.lowercased().contains(lower) ?? false)
                || (s.firstPrompt?.lowercased().contains(lower) ?? false)
                || s.tags.contains { $0.name.lowercased().contains(lower) }
                || s.uuid.lowercased().hasPrefix(lower)
            if let snip = snippetByUuid[s.uuid] { s.searchSnippet = snip }
            if inMeta {
                metaMatches.append(s)
            } else if s.searchSnippet != nil {
                contentMatches.append(s)
            }
        }
        return metaMatches + contentMatches
    }

    /// Search used by the ⌘K quick-search panel.
    func quickSearch(_ query: String) async -> [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let database = db
        let all = sessions
        return await Task.detached(priority: .userInitiated) {
            Self.computeSearch(db: database, all: all, query: q)
        }.value
    }

    // MARK: - Actions

    func open(_ session: SessionInfo) {
        let result = TerminalLauncher.open(session: session, terminal: terminalKind, claudeCommand: claudeCommand)
        switch result {
        case .opened: break
        case .copiedToClipboard(let reason): alertMessage = reason
        case .failed(let msg): alertMessage = msg
        }
    }

    func copyCommand(_ session: SessionInfo) {
        TerminalLauncher.copyToClipboard(session.resumeCommand)
    }

    /// Shell command used by the in-app terminal (honors the claudeCommand setting).
    func shellCommand(for session: SessionInfo) -> String {
        var command = session.resumeCommand
        if claudeCommand != "claude" {
            command = command.replacingOccurrences(of: "claude --resume", with: "\(claudeCommand) --resume")
        }
        return command
    }

    /// Continue a session in an embedded terminal window inside Chatwerk.
    func continueInApp(_ session: SessionInfo) {
        TerminalWindowManager.shared.open(session: session, command: shellCommand(for: session))
    }

    /// The user's chosen default: in-app terminal or external terminal app.
    func continueDefault(_ session: SessionInfo) {
        if openInAppDefault {
            continueInApp(session)
        } else {
            open(session)
        }
    }

    func updateMeta(_ session: SessionInfo, customTitle: String?, note: String?, favorite: Bool) {
        let title = customTitle?.isEmpty == true ? nil : customTitle
        let noteVal = note?.isEmpty == true ? nil : note
        db.setMeta(uuid: session.uuid, customTitle: title, note: noteVal, favorite: favorite)
        mutateSession(uuid: session.uuid) {
            $0.customTitle = title
            $0.note = noteVal
            $0.favorite = favorite
        }
    }

    func toggleFavorite(_ session: SessionInfo) {
        updateMeta(session, customTitle: session.customTitle, note: session.note, favorite: !session.favorite)
    }

    func createTag(name: String, colorHex: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        db.createTag(name: name.trimmingCharacters(in: .whitespaces), colorHex: colorHex)
        tags = db.allTags()
    }

    func deleteTag(_ tag: TagInfo) {
        db.deleteTag(id: tag.id)
        tags = db.allTags()
        for i in sessions.indices {
            sessions[i].tags.removeAll { $0.id == tag.id }
        }
        if case .tag(tag.id) = filter { filter = .all }
    }

    func setTag(_ session: SessionInfo, tag: TagInfo, on: Bool) {
        db.setTag(uuid: session.uuid, tagId: tag.id, on: on)
        mutateSession(uuid: session.uuid) { s in
            if on {
                if !s.tags.contains(where: { $0.id == tag.id }) { s.tags.append(tag) }
            } else {
                s.tags.removeAll { $0.id == tag.id }
            }
        }
    }

    func delete(_ session: SessionInfo) {
        do {
            try Cleaner.delete(session: session, liveSessionIds: liveIds)
            db.purgeSession(uuid: session.uuid)
            sessions.removeAll { $0.uuid == session.uuid }
            if selectedSessionId == session.id { selectedSessionId = nil }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func archive(_ session: SessionInfo, to dir: URL) {
        do {
            let zip = try Cleaner.archive(session: session, to: dir)
            alertMessage = "Archived to \(zip.lastPathComponent)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func mutateSession(uuid: String, _ change: (inout SessionInfo) -> Void) {
        for i in sessions.indices where sessions[i].uuid == uuid {
            change(&sessions[i])
        }
        if searchResults != nil {
            for i in searchResults!.indices where searchResults![i].uuid == uuid {
                change(&searchResults![i])
            }
        }
    }

    // MARK: - Stats

    struct Stats {
        var totalSessions: Int
        var totalSize: Int64
        var projects: [ProjectGroup]
        var largest: [SessionInfo]
    }

    var stats: Stats {
        Stats(totalSessions: sessions.count,
              totalSize: sessions.reduce(0) { $0 + $1.size },
              projects: projectGroups,
              largest: sessions.sorted { $0.size > $1.size }.prefix(15).map { $0 })
    }
}
