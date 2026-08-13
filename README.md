<p align="center">
  <img src="Chatwerk/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Chatwerk icon">
</p>

<h1 align="center">Chatwerk</h1>

<p align="center">
  <b>All your Claude Code chats in one place.</b><br>
  Browse, search, tag and resume every Claude Code session on your Mac — with one click.
</p>

---

If you use [Claude Code](https://claude.com/claude-code) a lot, you know the problem: dozens of sessions spread across projects, no overview, and finding *that one chat from last week* means grepping through `~/.claude` or keeping a text file full of `claude --resume <uuid>` commands.

Chatwerk fixes that.

## Features

- **📋 Every session, one list** — all sessions from all projects, sorted by last activity, with automatic titles, project, size, message count and git branch
- **🔍 Full-text search** — searches *inside* your chats (SQLite FTS5 index), not just titles. Press **⌘K** for a Spotlight-style quick search from anywhere in the app
- **🏷 Tags, notes & favorites** — organize sessions your way. Stored only in Chatwerk's own database, never inside `~/.claude`
- **▶️ One-click resume** — double-click a session and Chatwerk opens your terminal in the right project directory and runs `claude --resume <id>`. Supports **Terminal.app, iTerm2, Ghostty and Warp**
- **📄 Transcript viewer** — read any chat inside the app without resuming it; tool calls and thinking blocks stay collapsed. Export as Markdown
- **🟢 Live session badges** — see which sessions are running in Claude Code right now
- **📊 Statistics & cleanup** — sessions and disk usage per project, largest transcripts, safe archive (zip) and delete including all sidecar data
- **🔒 100% local** — Chatwerk reads your data from `~/.claude` and never sends anything anywhere

## Install

**Requirements:** macOS 14+, [Claude Code](https://claude.com/claude-code) installed and used at least once.

### Download

Grab the latest `Chatwerk.dmg` from [Releases](../../releases), drag Chatwerk to Applications.

> The app is not notarized yet. On first launch, right-click → **Open** (or allow it under System Settings → Privacy & Security).

### Build from source

```bash
brew install xcodegen
git clone https://github.com/serkanyildizdev/chatwerk.git
cd chatwerk
make app          # builds Release → dist/Chatwerk.app
```

Or open `Chatwerk.xcodeproj` in Xcode and hit Run.

## How it works

Claude Code stores every session as a JSONL transcript under `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. Chatwerk:

1. **Scans** those files (cheap `stat` pass every few seconds — new and changed sessions appear live)
2. **Reads only head/tail chunks** of each transcript for titles and metadata, so even 250 MB sessions list instantly
3. **Indexes** message text incrementally into a local SQLite FTS5 database (`~/Library/Application Support/Chatwerk/index.db`) — transcripts are append-only, so only new bytes get parsed
4. **Resumes** sessions by telling your terminal to run `cd <project> && claude --resume <uuid>`

Your notes, tags, favorites and custom titles live only in Chatwerk's database. Chatwerk never modifies `~/.claude` — except when *you* explicitly archive or delete a session, which also removes its sidecar folders (`file-history`, `tasks`, subagent transcripts).

## FAQ

**Does it work with the Claude Code versions before 2.x?**
Chatwerk reads `ai-title` lines written by recent Claude Code versions and falls back to the first user prompt for older transcripts.

**Why does deleting ask about "sidecar data"?**
A session is more than its transcript: Claude Code also keeps file-edit backups, background task state and subagent transcripts. Chatwerk removes all of it so nothing is left behind.

**Warp support?**
Warp can't be scripted with AppleScript, so Chatwerk drives it with a [Launch Configuration](https://docs.warp.dev/features/sessions/launch-configurations): the resume command runs automatically in the right directory. The command is also copied to your clipboard as a fallback for older Warp versions.

**What permissions does Chatwerk need?**
Just one, and only once: permission to send your terminal app the resume command (macOS "Automation" prompt on first use). Chatwerk reads `~/.claude` directly — that requires no permission — and never touches anything else.

## Disclaimer

Chatwerk is an independent, unofficial tool made by [Sewerk](https://sewerk.de). It is **not affiliated with, endorsed by, or sponsored by Anthropic**. "Claude" and "Claude Code" are trademarks of Anthropic, PBC — the names are used here only to describe compatibility. Chatwerk ships no Anthropic assets and talks to no Anthropic services; it only reads the local files Claude Code keeps on your own machine.

## License

MIT © [Sewerk](https://sewerk.de)
