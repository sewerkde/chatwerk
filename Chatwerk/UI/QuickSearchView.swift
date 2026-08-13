import SwiftUI

/// Spotlight-style quick search (⌘K), shown as a centered overlay panel.
/// Live results, arrow keys or hover to move, Return resumes the session,
/// ⌘Return reveals it in the list. With an empty query it doubles as a
/// session switcher showing the most recent chats.
struct QuickSearchView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("accentName") private var accentName: String = "Sewerk Orange"

    @State private var query = ""
    @State private var results: [SessionInfo] = []
    @State private var selectedIndex = 0
    @State private var searching = false
    @FocusState private var fieldFocused: Bool

    private var accent: Color { Theme.accent(accentName) }

    private var isRecents: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Recents with an empty query, search hits otherwise.
    private var displayed: [SessionInfo] {
        isRecents ? Array(state.sessions.prefix(10)) : Array(results.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search sessions, notes, tags and chat content…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openSelected() }
                if searching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if displayed.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(Array(displayed.enumerated()), id: \.element.id) { index, session in
                        QuickSearchRow(session: session, accent: accent, isSelected: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                selectedIndex = index
                                openSelected()
                            }
                            .onTapGesture {
                                selectedIndex = index
                                revealSelected()
                            }
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if isRecents {
                            HStack {
                                Text("Recents")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↩", "continue")
                hint("⌘↩", "show in list")
                hint("↑↓", "navigate")
                hint("esc", "close")
                Spacer()
                if !isRecents {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 640, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in
            searchNow()
        }
        .onKeyPress(.downArrow) {
            guard !displayed.isEmpty else { return .ignored }
            selectedIndex = min(selectedIndex + 1, displayed.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !displayed.isEmpty else { return .ignored }
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            revealSelected()
            return .handled
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.bold())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func close() {
        state.showQuickSearch = false
    }

    private func searchNow() {
        guard !isRecents else {
            results = []
            selectedIndex = 0
            searching = false
            return
        }
        searching = true
        let q = query
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard q == query else { return }
            let found = await state.quickSearch(q)
            guard q == query else { return }
            results = found
            selectedIndex = 0
            searching = false
        }
    }

    private func openSelected() {
        guard displayed.indices.contains(selectedIndex) else { return }
        let session = displayed[selectedIndex]
        close()
        state.open(session)
    }

    private func revealSelected() {
        guard displayed.indices.contains(selectedIndex) else { return }
        let session = displayed[selectedIndex]
        close()
        state.filter = .all
        state.searchText = ""
        state.searchResults = nil
        state.selectedSessionId = session.id
    }
}

private struct QuickSearchRow: View {
    let session: SessionInfo
    let accent: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isLive ? "dot.radiowaves.left.and.right" : "bubble.left")
                .foregroundStyle(session.isLive ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if session.favorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
                    }
                    Spacer()
                    Text(session.modifiedAt.relativeString)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let snippet = session.searchSnippet {
                        Text(SnippetText.highlighted(snippet, font: .caption, accent: accent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Renders FTS snippets, turning ⟪match⟫ markers into bold accent text.
enum SnippetText {
    static func highlighted(_ snippet: String, font: Font = .caption, accent: Color = .orange) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: "⟪"),
              let close = rest.range(of: "⟫", range: open.upperBound..<rest.endIndex) {
            result += AttributedString(String(rest[rest.startIndex..<open.lowerBound]))
            var match = AttributedString(String(rest[open.upperBound..<close.lowerBound]))
            match.font = font.bold()
            match.foregroundColor = accent
            result += match
            rest = rest[close.upperBound...]
        }
        result += AttributedString(String(rest))
        return result
    }
}
