<p align="center">
  <img src="Chatwerk/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Chatwerk icon">
</p>

<h1 align="center">Chatwerk</h1>

<p align="center">
  <b>All your Claude Code chats in one place.</b><br>
  Browse, search, tag and resume every Claude Code session on your Mac — with one click.
</p>

<p align="center">
  <a href="../../releases"><img src="https://img.shields.io/github/v/release/sewerkde/chatwerk?include_prereleases&label=release&color=FF6A00" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen" alt="Zero dependencies">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
  <a href="../../actions"><img src="https://img.shields.io/github/actions/workflow/status/sewerkde/chatwerk/ci.yml?label=build" alt="CI"></a>
</p>

---

If you use [Claude Code](https://claude.com/claude-code) a lot, you know the problem: dozens of sessions spread across projects, no overview, and finding *that one chat from last week* means grepping through `~/.claude` or keeping a text file full of `claude --resume <uuid>` commands.

Chatwerk fixes that.

## Features

- **📋 Every session, one list** — all sessions from all projects with automatic titles, grouped by time (Today / Yesterday / This Week / …), with size, message count and last-prompt preview per row
- **🔍 Full-text search** — searches *inside* your chats (SQLite FTS5 index, built incrementally in the background). Press **⌘K** for a Spotlight-style quick search: type, arrow keys, hit ↩ to resume
- **🏷 Tags, notes & favorites** — organize sessions your way; an **Unsorted** smart filter surfaces chats you haven't organized yet, so nothing gets lost. Stored only in Chatwerk's own database, never inside `~/.claude`
- **▶️ One-click resume** — double-click (or ⌘↩) and your terminal opens in the right project directory running `claude --resume <id>`. Supports **Terminal.app, iTerm2, Ghostty and Warp** (Warp via Launch Configurations — the command runs automatically)
- **🟢 Live status** — running sessions are badged in real time: green **Working…** while Claude is busy, orange **Your turn** row highlight the moment Claude finishes and waits for you
- **🔔 Ready alerts** — optional sound (14 system tones) and notification banner when Claude finishes responding; click the banner to jump straight to that chat
- **📄 Transcript viewer** — read any chat without resuming it: newest exchange on top (flippable), chat-style bubbles with role avatars and timestamps, inline markdown + code blocks rendered, tool runs collapsed into single "background steps" rows. Export as Markdown
- **📊 Statistics & cleanup** — sessions and disk usage per project, largest transcripts, safe archive (zip) and delete including every sidecar folder Claude Code keeps
- **🎨 Themes** — light/dark/system plus 8 accent colors, all dark-mode tuned
- **🖥 Menu bar** — recent sessions and alert toggle one click away
- **🔒 100% local & zero permissions** — Chatwerk reads your data from disk and never sends anything anywhere. The only permission it ever asks for is the one-time macOS Automation prompt to drive your terminal

## Install

**Requirements:** macOS 14+, [Claude Code](https://claude.com/claude-code) installed and used at least once.

### Download

Grab the latest `Chatwerk.dmg` from [Releases](../../releases), drag Chatwerk to Applications.

> The app is not notarized yet. On first launch, right-click → **Open** (or allow it under System Settings → Privacy & Security).

### Build from source

```bash
brew install xcodegen
git clone https://github.com/sewerkde/chatwerk.git
cd chatwerk
make app          # builds Release → dist/Chatwerk.app
```

Or run `xcodegen generate` and open `Chatwerk.xcodeproj` in Xcode. The app is pure Swift/SwiftUI with **zero third-party dependencies** — the full text index uses the system SQLite's FTS5.

## How it works

Claude Code stores every session as a JSONL transcript under `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. Chatwerk:

1. **Scans** those files with a cheap stat pass every few seconds — new and changed sessions appear live, and `~/.claude/sessions` tells it which ones are running right now
2. **Reads only head/tail chunks** of each transcript for titles (Claude Code's own `ai-title` lines) and metadata, so even 250 MB sessions list instantly
3. **Indexes** message text incrementally into a local SQLite FTS5 database (`~/Library/Application Support/Chatwerk/index.db`) — transcripts are append-only, so only new bytes get parsed
4. **Resumes** sessions by telling your terminal to run `cd <project> && claude --resume <uuid>`

Your notes, tags, favorites and custom titles live only in Chatwerk's database. Chatwerk never modifies `~/.claude` — except when *you* explicitly archive or delete a session, which also removes its sidecar folders (`file-history`, `tasks`, subagent transcripts).

## FAQ

**What permissions does Chatwerk need?**
Just one, and only once: permission to send your terminal app the resume command (macOS "Automation" prompt on first use). Chatwerk reads `~/.claude` directly — that requires no permission — and never touches anything else.

**I run Claude Code with `CLAUDE_CONFIG_DIR` — will it find my sessions?**
Yes: point Settings → *Data folder* at your custom directory. The `claude` binary path is configurable there too.

**Why does deleting ask about "sidecar data"?**
A session is more than its transcript: Claude Code also keeps file-edit backups, background task state and subagent transcripts. Chatwerk removes all of it so nothing is left behind.

**Warp support?**
Warp can't be scripted with AppleScript, so Chatwerk drives it with a [Launch Configuration](https://docs.warp.dev/features/sessions/launch-configurations): the resume command runs automatically in the right directory. The command is also copied to your clipboard as a fallback for older Warp versions.

**Will you support other AI CLIs (Codex, Gemini CLI, …)?**
Maybe later — the scanner/indexer layer is provider-shaped, but v1 stays focused on doing one thing well. Open an issue if you'd use it.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev setup and a map of the codebase. Bug reports and feature ideas via [Issues](../../issues) — and if Chatwerk saves you time, a ⭐ helps others find it.

## Roadmap

- Local-AI chat summaries and auto-tag suggestions (fully offline)
- Global quick-search hotkey (system-wide ⌘K)
- Notarized builds + Homebrew cask

## Disclaimer

Chatwerk is an independent, unofficial tool made by [Sewerk](https://sewerk.de). It is **not affiliated with, endorsed by, or sponsored by Anthropic**. "Claude" and "Claude Code" are trademarks of Anthropic, PBC — the names are used here only to describe compatibility. Chatwerk ships no Anthropic assets and talks to no Anthropic services; it only reads the local files Claude Code keeps on your own machine.

## License

MIT © [Sewerk](https://sewerk.de)
