# Security and privacy

AgentBar is a menu bar app that shows your AI coding agents' usage limits and token counts. This
page lists everything it reads, sends, runs and writes, so you can decide whether to run it.
Each claim below maps to code in `Sources/AgentBar/`. Build from source if you'd rather not trust
a download.

## In short

- **One network request of its own:** your Claude usage, from Anthropic. Nothing else leaves your
  Mac, and nothing goes to the author or any third party.
- **No telemetry, analytics, crash reporting or update checks.**
- **Read-only on your agents' files.** AgentBar never writes to `~/.claude`, `~/.codex`, `~/.grok`
  or any agent's credentials.
- **Your Claude sign-in token stays in memory.** It is sent only to Anthropic's usage endpoint, and
  is never logged, printed or saved to disk.

## Network

| When | Request | Why |
|---|---|---|
| At launch, every refresh interval (default 15 min, 30 s–60 min in settings), when the panel opens (at most every 15 s), and when you press r | `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <Claude Code token>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json` | Claude's session and weekly limits, exactly as Omarchy's collector asks for them |

A `429 Too Many Requests` answer is respected: no panel-triggered request is made before its
`Retry-After` has passed. The exact request and response handling are in `reference/request.md`
and `Sources/AgentBar/Claude/ClaudeUsageAPI.swift`.

**Codex** is the one exception to "one request". If the `codex` command is installed, AgentBar runs
`codex -s read-only -a on-request app-server` and asks it for your account and rate limits over
standard input and output, the way Omarchy does. Codex then talks to OpenAI itself, using its own
sign-in, and may update its own files in `~/.codex` (for example to refresh its sign-in). AgentBar
never reads Codex's credentials. Turn Codex off in settings and it isn't run at all.

## What it reads

All reads are local and read-only.

| What | Where | Used for |
|---|---|---|
| Claude Code's sign-in | macOS Keychain item `Claude Code-credentials`, read by running `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` | The token for the usage request, its expiry, and your plan name. macOS may ask you to allow this; you can revoke it in Keychain Access. |
| Claude Code transcripts | `~/.claude/projects/**/*.jsonl` (or `$CLAUDE_CONFIG_DIR`) | Token counts per day and per model. Each line is parsed, but only its usage numbers, model, time and session id are kept; message text isn't stored, shown or sent. |
| Claude Code fallbacks | `~/.claude/stats-cache.json`, `~/.claude/history.jsonl` | Totals when there are no transcripts. From `history.jsonl` only timestamps and session ids are kept. |
| Codex sessions | `~/.codex/sessions`, `~/.codex/archived_sessions` (or `$CODEX_HOME`), files changed in the last 30 days | Token counts from `token_count` events |
| Grok sessions | `~/.grok/sessions/*/*/usage.json` | Token counts per turn |
| Grok's log | `~/.grok/logs/unified.jsonl`, only lines reading `billing: fetched credits config` | Grok's weekly credit percentage, billing period and plan. `~/.grok/auth.json` is never opened. |
| pi, omp, opencode | `~/.pi/agent/sessions`, `~/.omp/agent/sessions`, `~/.local/share/opencode/opencode.db` (opened read-only) | Usage those tools spent on Anthropic or OpenAI subscriptions |
| Your choices | A theme folder or sync folder, if you pick one | Colours; other machines' usage snapshots |

## What it writes

| What | Where | Contents |
|---|---|---|
| Usage records | `~/Library/Application Support/AgentBar/records/<agent>.json` (or your records folder) | Plan name, limits, token and prompt counts per day and model, status text. No tokens, no conversation text. |
| Caches | `~/Library/Caches/AgentBar/` | The last Claude limits (numbers only), the last local scans (counts only), and `launch-agent.command`, the small script right click opens in Terminal |
| Settings | `~/Library/Preferences/io.github.sammathew4444.AgentBar.plist` | Your settings and theme |
| Sync snapshot | `<sync folder>/<hostname>.json`, only when synced aggregation is on | This Mac's token and prompt counts per day and model, and the device name. No limits, tokens, file paths or conversation text. Anything with access to that folder can read it. |
| Login item | macOS Login Items | Only if you turn on Launch at login |

## What it runs

| Program | When |
|---|---|
| `/usr/bin/security` | To read Claude Code's sign-in, as above |
| `codex -s read-only -a on-request app-server` | Each refresh, if Codex is installed and enabled |
| Terminal, running your agent command (`claude` by default) | Only when you right-click the robot |

## The app itself

- **Not signed with a Developer ID and not notarized.** Downloads are ad-hoc signed zips built by
  GitHub Actions from this repository's tagged commits (see `.github/workflows/ci.yml`), each with
  a SHA-256 checksum. macOS quarantines them; the README explains how to open one.
- **Not sandboxed**, because it needs to read your agents' files.
- **No third-party dependencies.** It uses Apple's frameworks only. The bundled font is
  JetBrainsMono Nerd Font (SIL OFL), and the themes and agent logos come from Omarchy (MIT).

## Reporting a problem

Please report security issues privately through this repository's **Security › Report a
vulnerability** page on GitHub. For anything else, open an issue.
