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
