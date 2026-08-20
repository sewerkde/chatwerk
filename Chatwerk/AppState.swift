import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {

    /// Set once at launch; used by the notification-click handler.
    static weak var shared: AppState?
    /// Captured by MainView so notification clicks can re-front the window.
    weak var mainWindow: NSWindow?

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
    @Published var showQuickSearch = false
    /// Claude Code's transcript retention (cleanupPeriodDays, default 30):
    /// sessions idle longer than this get auto-deleted by Claude Code itself.
    @Published var retentionDays: Int = 30

    let db: Database
    private var indexer: Indexer?
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastScanSignature: String = ""

    // Settings
    @AppStorage("terminalKind") var terminalKindRaw: String = TerminalKind.terminal.rawValue
    @AppStorage("claudeCommand") var claudeCommand: String = "claude"
    @AppStorage("showMenuBarExtra") var showMenuBarExtra: Bool = true
    /// Alert when a running session finishes responding (busy → idle).
    @AppStorage("notifyWhenReady") var notifyWhenReady: Bool = true
    @AppStorage("notifyWithBanner") var notifyWithBanner: Bool = true
    @AppStorage("notifyWithSound") var notifyWithSound: Bool = true
    @AppStorage("readySound") var readySound: String = "Glass"

    var terminalKind: TerminalKind {
        TerminalKind(rawValue: terminalKindRaw) ?? .terminal
    }

    init() {
        db = Self.openDatabase()
        claudeDirMissing = !ClaudePaths.exists
        retentionDays = Self.readRetentionDays()
        sessions = Self.deduped(db.loadAllSessions())
        tags = db.allTags()
        refreshLive()
        startBackgroundWork()
        Self.shared = self
        NotificationDelegate.shared.install()
    }

    /// The index is a rebuildable cache: if it can't be opened (corruption,
    /// interrupted migration), move it aside and start fresh instead of dying.
    private nonisolated static func openDatabase() -> Database {
        let url = ClaudePaths.databaseURL
        if let db = try? Database(url: url) { return db }
        let fm = FileManager.default
        let broken = url.appendingPathExtension("broken")
        try? fm.removeItem(at: broken)
        try? fm.moveItem(at: url, to: broken)
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        do {
            return try Database(url: url)
        } catch {
            fatalError("Chatwerk could not create its index database at \(url.path): \(error)")
        }
    }

    /// Bring the app forward and select a session (used by notification clicks).
    func reveal(sessionUuid: String) {
        filter = .all
        searchText = ""
        searchResults = nil
        if let session = sessions.first(where: { $0.uuid == sessionUuid }) {
            selectedSessionId = session.id
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
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
            case .expiring: base = base.filter { daysUntilCleanup(for: $0) <= 7 }
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
                self.refreshPlanUsage()
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

    /// cleanupPeriodDays from ~/.claude/settings.json (Claude Code's default: 30).
    nonisolated static func readRetentionDays() -> Int {
        let url = ClaudePaths.claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let days = (obj["cleanupPeriodDays"] as? NSNumber)?.intValue else { return 30 }
        return days
    }

    /// Days until Claude Code's cleanup would delete this transcript.
    func daysUntilCleanup(for session: SessionInfo) -> Int {
        retentionDays - Int(Date().timeIntervalSince(session.modifiedAt) / 86_400)
    }

    /// Expiring within a week (only meaningful with short retention settings).
    var expiringCount: Int {
        sessions.filter { daysUntilCleanup(for: $0) <= 7 }.count
    }

    private func rescanIfChanged() async {
        let sig = await Task.detached(priority: .utility) { Self.scanSignature() }.value
        let days = await Task.detached(priority: .utility) { Self.readRetentionDays() }.value
        if days != retentionDays { retentionDays = days }
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
                // Stamp transient state before comparing, so an unchanged scan
                // publishes nothing and the UI isn't churned every poll.
                var stamped = loaded
                for i in stamped.indices {
                    stamped[i].isLive = self.liveIds.contains(stamped[i].uuid)
                    stamped[i].liveStatus = self.liveStatusById[stamped[i].uuid]
                }
                if stamped != self.sessions {
                    self.sessions = stamped
                }
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
                                           sessionUuid: sessionId,
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

    func open(_ session: SessionInfo, in terminal: TerminalKind? = nil) {
        let kind = terminal ?? terminalKind
        let result = TerminalLauncher.open(session: session, terminal: kind, claudeCommand: claudeCommand)
        switch result {
        case .opened:
            break
        case .copiedToClipboard(let reason):
            // Warp always goes through the clipboard; explain it once,
            // then stay quiet instead of nagging on every resume.
            if kind == .warp {
                if !UserDefaults.standard.bool(forKey: "warpCopyHintShown") {
                    UserDefaults.standard.set(true, forKey: "warpCopyHintShown")
                    alertMessage = reason
                }
            } else {
                alertMessage = reason
            }
        case .failed(let msg):
            alertMessage = msg
        }
    }

    func copyCommand(_ session: SessionInfo) {
        TerminalLauncher.copyToClipboard(session.resumeCommand)
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

    /// Distinct tag groups, for the editor's picker and the sidebar layout.
    var tagGroups: [String] {
        Array(Set(tags.compactMap { $0.group?.isEmpty == false ? $0.group : nil }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @discardableResult
    func createTag(name: String, colorHex: String, group: String? = nil) -> TagInfo? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tag = db.createTag(name: trimmed, colorHex: colorHex, group: group)
        tags = db.allTags()
        return tag
    }

    func updateTag(_ tag: TagInfo, name: String, colorHex: String, group: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        db.updateTag(id: tag.id, name: trimmed, colorHex: colorHex, group: group)
        tags = db.allTags()
        // Refresh the copies embedded in loaded sessions.
        let fresh = tags.first { $0.id == tag.id }
        func apply(_ list: inout [SessionInfo]) {
            for i in list.indices {
                for j in list[i].tags.indices where list[i].tags[j].id == tag.id {
                    if let fresh { list[i].tags[j] = fresh }
                }
            }
        }
        apply(&sessions)
        if var results = searchResults {
            apply(&results)
            searchResults = results
        }
    }

    /// How many sessions carry each tag (for ordering big tag lists).
    var tagUsageCounts: [Int64: Int] {
        var counts: [Int64: Int] = [:]
        for s in sessions {
            for t in s.tags { counts[t.id, default: 0] += 1 }
        }
        return counts
    }

    /// Writes a dated backup folder: a consistent copy of the index database
    /// (tags, notes, favorites, usage, search index) plus the app settings.
    func exportBackup(to directory: URL) throws -> URL {
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm"
            return f.string(from: Date())
        }()
        let folder = directory.appendingPathComponent("Chatwerk Backup \(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try db.backup(to: folder.appendingPathComponent("index.db"))

        let settingKeys = ["terminalKind", "claudeCommand", "showMenuBarExtra",
                           "notifyWhenReady", "notifyWithBanner", "notifyWithSound",
                           "readySound", "appearance", "accentName", "claudeDataDir",
                           "showInfoPanel", "transcriptNewestFirst"]
        var settings: [String: Any] = [:]
        for key in settingKeys {
            if let value = UserDefaults.standard.object(forKey: key) { settings[key] = value }
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("settings.json"))
        return folder
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
            searchResults?.removeAll { $0.uuid == session.uuid }
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
        if var results = searchResults {
            for i in results.indices where results[i].uuid == uuid {
                change(&results[i])
            }
            searchResults = results
        }
    }

    // MARK: - Plan limits (opt-in, Claude Code's /usage numbers)

    @AppStorage("showPlanLimits") var showPlanLimits: Bool = false
    @Published var planUsage: PlanUsage.Snapshot?
    @Published var planUsageError: String?
    private var planFetchedAt: Date?

    /// Refreshes the server-side plan utilization. Throttled to the endpoint's
    /// safe cadence (3 min) unless forced from the Settings toggle.
    func refreshPlanUsage(force: Bool = false) {
        guard showPlanLimits else { return }
        if !force, let last = planFetchedAt, Date().timeIntervalSince(last) < 180 { return }
        planFetchedAt = Date()
        Task { [weak self] in
            do {
                let snapshot = try await PlanUsage.fetch()
                self?.planUsage = snapshot
                self?.planUsageError = nil
            } catch {
                self?.planUsageError = (error as? PlanUsage.FetchError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Usage summary (menu bar)

    struct UsagePeriod {
        var tokens: Int64 = 0
        var cost: Double = 0
    }

    struct ModelPeriod {
        var model: String
        var displayName: String
        var tokens: Int64
        var cost: Double
    }

    struct UsageSummary {
        var window5h = UsagePeriod()
        var today = UsagePeriod()
        var last7d = UsagePeriod()
        var month = UsagePeriod()
        var byModel7d: [ModelPeriod] = []
    }

    /// Sums indexed usage into the windows shown in the menu bar. Boundaries
    /// are UTC — the clock the transcripts are written in. This is our own
    /// local estimate; Anthropic does not expose remaining plan quota.
    func usageSummary() -> UsageSummary {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let hourF = DateFormatter()
        hourF.dateFormat = "yyyy-MM-dd'T'HH"
        hourF.timeZone = utc
        let dayF = DateFormatter()
        dayF.dateFormat = "yyyy-MM-dd"
        dayF.timeZone = utc

        let now = Date()
        let today = dayF.string(from: now)
        let hour5 = hourF.string(from: now.addingTimeInterval(-5 * 3600))
        let day7 = dayF.string(from: now.addingTimeInterval(-7 * 86_400))
        let monthPrefix = String(today.prefix(7))
        // Fetch far enough back to cover both the rolling 7 days and the month.
        let fetchFrom = min(day7, monthPrefix + "-01")

        var summary = UsageSummary()
        var models: [String: (tokens: Int64, cost: Double)] = [:]
        for row in db.hourlyRows(since: fetchFrom) {
            let tokens = row.input + row.output + row.cacheRead + row.cacheWrite
            let cost = Pricing.cost(model: row.model, input: row.input, output: row.output,
                                    cacheRead: row.cacheRead, cacheWrite: row.cacheWrite,
                                    cacheWrite1h: row.cacheWrite1h) ?? 0
            let day = String(row.hour.prefix(10))
            if row.hour >= hour5 { summary.window5h.tokens += tokens; summary.window5h.cost += cost }
            if day == today { summary.today.tokens += tokens; summary.today.cost += cost }
            if day >= day7 {
                summary.last7d.tokens += tokens; summary.last7d.cost += cost
                var entry = models[row.model] ?? (0, 0)
                entry.tokens += tokens; entry.cost += cost
                models[row.model] = entry
            }
            if day.hasPrefix(monthPrefix) { summary.month.tokens += tokens; summary.month.cost += cost }
        }
        summary.byModel7d = models.map { model, value in
            ModelPeriod(model: model, displayName: Pricing.displayName(for: model),
                        tokens: value.tokens, cost: value.cost)
        }
        .sorted { $0.cost > $1.cost }
        return summary
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
