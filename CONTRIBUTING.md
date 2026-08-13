# Contributing to Chatwerk

Thanks for your interest! Chatwerk is a small, focused codebase — you can read all of it in an afternoon.

## Dev setup

```bash
brew install xcodegen
git clone https://github.com/serkanyildizdev/chatwerk.git
cd chatwerk
xcodegen generate        # produces Chatwerk.xcodeproj from project.yml
open Chatwerk.xcodeproj  # …or: make app
```

Requirements: Xcode 15+, macOS 14+. No package dependencies — the project must stay **zero-dependency** (system SQLite, AppKit, SwiftUI only) unless there's a very good reason.

The project file is generated: edit `project.yml`, not the `.xcodeproj`, and re-run `xcodegen generate`.

## Codebase map

```
Chatwerk/
├── ChatwerkApp.swift        App entry: scenes, menu bar extra
├── AppState.swift           Single observable state: scanning, indexing,
│                            search, live-session polling, actions
├── Models.swift             SessionInfo, filters, TerminalKind, Theme
├── Core/
│   ├── ClaudePaths.swift    Where Claude Code keeps its data on disk
│   ├── JSONL.swift          Chunked line reader for huge transcripts
│   ├── SessionScanner.swift Cheap stat scan + head/tail metadata parse
│   ├── Indexer.swift        Incremental FTS5 indexing (byte-offset resume)
│   ├── Database.swift       SQLite wrapper: sessions cache, FTS, tags/notes
│   ├── TranscriptLoader.swift  Tail-window transcript parsing + markdown utils
│   ├── TerminalLauncher.swift  AppleScript / Warp launch-config resume
│   ├── LiveSessions.swift   Detecting running Claude Code processes
│   ├── Notifier.swift       Ready-alerts (sound + notification routing)
│   └── Cleaner.swift        Archive/delete incl. all sidecar folders
└── UI/                      SwiftUI views (Main, Detail, QuickSearch, …)
```

Key invariants — please keep them:

- **Never write into `~/.claude`** except in `Cleaner` (explicit user action). User metadata lives only in Chatwerk's own database.
- **Never load whole transcripts.** Files can exceed 250 MB; use `JSONL.readLines` chunking, head/tail windows and byte-offset resumes.
- **Nothing leaves the machine.** No network calls, no telemetry — ever.
- **Zero permission prompts** beyond the one-time terminal-Automation dialog.
- List interactions must stay instant: no tap gestures on List rows (use `primaryAction`), no per-render formatter allocations.

## Pull requests

- One topic per PR, with a short description of the user-visible effect.
- `xcodebuild -configuration Release build` must pass with **zero warnings**.
- UI changes: include a screenshot (light + dark if colors are involved).
- New behavior that needs a knob belongs in Settings, defaulted sensibly.

## Reporting bugs

Please include: macOS version, Claude Code version (`claude --version`), roughly how many sessions you have (`ls ~/.claude/projects/*/ | grep -c jsonl`), and Console output from Chatwerk if there is any.
