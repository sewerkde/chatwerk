import SwiftUI

/// Spotlight-style quick search (⌘K): live results, arrow keys to move,
/// Return resumes the session in the terminal, ⌘Return shows it in the list.
struct QuickSearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var query = ""
    @State private var results: [SessionInfo] = []
    @State private var selectedIndex = 0
    @State private var searching = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all your Claude chats…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openSelected() }
                if searching {
                    ProgressView().controlSize(.small)
                }
                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                VStack(spacing: 4) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Type to search titles, notes, tags and full chat content.")
                    } else if !searching {
                        Text("No matches for “\(query)”.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    List(Array(results.prefix(50).enumerated()), id: \.element.id) { index, session in
                        QuickSearchRow(session: session, isSelected: index == selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = index
                                openSelected()
                            }
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 340)
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue)
                    }
                }
                HStack(spacing: 14) {
                    hint("↩", "continue session")
                    hint("⌘↩", "show in list")
                    hint("↑↓", "navigate")
                    Spacer()
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .frame(width: 640)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in
            searchNow()
        }
        .onKeyPress(.downArrow) {
            guard !results.isEmpty else { return .ignored }
            selectedIndex = min(selectedIndex + 1, min(results.count, 50) - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !results.isEmpty else { return .ignored }
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
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

    private func searchNow() {
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
        guard results.indices.contains(selectedIndex) else { return }
        let session = results[selectedIndex]
        dismiss()
        if state.openInAppDefault {
            openWindow(id: "terminal", value: session.id)
        } else {
            state.open(session)
        }
    }

    private func revealSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let session = results[selectedIndex]
        dismiss()
        state.filter = .all
        state.searchText = ""
        state.searchResults = nil
        state.selectedSessionId = session.id
    }
}

private struct QuickSearchRow: View {
    let session: SessionInfo
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
                    Text(session.modifiedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let snippet = session.searchSnippet {
                        Text(SnippetText.highlighted(snippet, font: .caption))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Renders FTS snippets, turning ⟪match⟫ markers into bold accent text.
enum SnippetText {
    static func highlighted(_ snippet: String, font: Font = .caption) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: "⟪"),
              let close = rest.range(of: "⟫", range: open.upperBound..<rest.endIndex) {
            result += AttributedString(String(rest[rest.startIndex..<open.lowerBound]))
            var match = AttributedString(String(rest[open.upperBound..<close.lowerBound]))
            match.font = font.bold()
            match.foregroundColor = .orange
            result += match
            rest = rest[close.upperBound...]
        }
        result += AttributedString(String(rest))
        return result
    }
}
