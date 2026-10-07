# Security Policy

Chatwerk runs entirely on your Mac. It reads the transcripts Claude Code keeps
under `~/.claude`, builds a local index in `~/Library/Application Support/Chatwerk`,
and never sends anything over the network. There is no account, no telemetry and
no update check in the app itself.

## What Chatwerk touches

- **Reads:** `~/.claude/projects` (transcripts), `~/.claude/sessions` (running
  processes), `~/.claude/settings.json` (retention days).
- **Writes:** only its own database and preferences — plus, when *you* choose
  archive or delete on a session, that session's files inside `~/.claude`.
- **Executes:** one command in your terminal app when you resume a session:
  `cd <project> && claude --resume '<id>'`. The id is taken from the transcript's
  file name, accepted only when it consists of uuid characters, and shell-quoted.

## Reporting a vulnerability

If you find a way for Chatwerk to leak data, run something it shouldn't, or
damage files outside its own database, please report it privately rather than
in a public issue:

- GitHub: use *Report a vulnerability* under the repository's **Security** tab, or
- E-mail: security@sewerk.de

Include the Chatwerk version (About window or `brew info chatwerk`), macOS
version and the steps to reproduce. You should hear back within a few days;
fixes ship as a new release and are credited in the release notes unless you
prefer otherwise.

## Supported versions

Only the latest release receives fixes. Update with
`brew upgrade --cask chatwerk` or from the Releases page.
