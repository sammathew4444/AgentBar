Synthetic usage records for tests. They are **not** captures from a real install; those belong in
`reference/records/` and are decoded by their own test.

Each file follows the record its collector builds at the pinned Omarchy commit
(`reference/source/bin/omarchy-agent-usage-*`): the same keys, key order and number formatting,
the collector's `AGENT_ID`, `AGENT_NAME` and `AUTH_HELP` strings, and its limit label formats.
The numbers are made up. `tierLabel` is left empty rather than guessing a plan name.

- `claude.json` — compact and key-sorted as `print(json.dumps(record, separators=(",", ":"), sort_keys=True))`
  writes it. Its `limits` are exactly the expected output of
  `reference/source/test/shell.d/agent-usage-claude-limits-test.sh`.
- `codex.json` — unsorted, in the order `main()` assembles it; limits labelled by `limit_window`.
- `fireworks.json` — `base_record` with an estimated prepaid `balance`.

`local/` holds the inputs to the local usage scan, read with the clock fixed at
2026-09-14T15:00:00Z in UTC, so the numbers the tests assert are reproducible.

- `local/claude/projects/` — Claude Code transcripts. `example/` has the lines from Omarchy's
  `agent-usage-claude-scanner-test.sh` (a message repeated across two lines counts once), plus a
  user line and a malformed line; `older/` adds days inside and outside the week and a
  zero-token message.
- `local/history/` — a `history.jsonl` on its own: two prompts today and one long ago.
- `local/stats-cache/` — a `stats-cache.json` on its own, for the aggregate fallback.
- `local/pi/`, `local/omp/` — pi and omp sessions from the same Omarchy test, one Anthropic
  message each among other providers.

The opencode database is built by the test itself, from the same Omarchy test's rows.

Codex, from Omarchy's `agent-usage-codex-scanner-test.sh`:

- `local/codex/sessions/` — a native Codex session: a `turn_context` and two `token_count` turns.
- `local/codex-pi/`, `local/codex-omp/` — pi and omp sessions through `openai-codex`, plus a
  message on another provider that must not count.
- `local/codex-bin/codex` — a POSIX shell stand-in for `codex app-server` that answers the three
  JSON-RPC requests with `CODEX_ACCOUNT` / `CODEX_RATE_LIMITS`, stays silent with `CODEX_SILENT`,
  and records its arguments to `CODEX_ARGS_FILE`. It needs only `sed` and `printf`.
