# Claude usage request

Written from the collector source at the pinned commit, not from memory:
`source/bin/omarchy-agent-usage-claude` (`USAGE_ENDPOINT`, `probe_limits`, `oauth_login`,
`collect_limits`). Line numbers refer to that file.

## Credentials (`oauth_login`, l. 584)

Omarchy reads `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude`). On macOS Claude Code
keeps the same JSON in the login Keychain as the generic password `Claude Code-credentials`.

```json
{ "claudeAiOauth": { "accessToken": "…", "expiresAt": 1789398000000,
                     "rateLimitTier": "…max_20x…", "subscriptionType": "max" } }
```

- `accessToken` goes only into the `Authorization` header.
- `expiresAt` is epoch milliseconds. If it is in the past, the collector does not call the
  endpoint and reports "Sign-in expired". No refresh flow.
- Plan label (`plan_label`): `rateLimitTier` matching `max_(\d+x)` becomes `Max 20x`; otherwise
  `subscriptionType` with its first letter capitalised; otherwise empty.

## Request (`probe_limits`, l. 711)

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
```

No body. Timeout 10 s. Those three headers are the only ones the collector sets. Everything else
(User-Agent, Accept-Encoding, Connection) is whatever the HTTP client adds on its own.

## Response

A JSON object. Fields the collector reads:

```json
{
  "five_hour":            { "utilization": 78.0, "resets_at": "2026-09-14T18:00:00+00:00" },
  "seven_day":            { "utilization": 12.0, "resets_at": "…" },
  "seven_day_oauth_apps": { "utilization": …,    "resets_at": "…" },
  "seven_day_opus": null,
  "limits": [
    { "kind": "weekly_scoped", "percent": 17, "resets_at": "…",
      "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" }, "surface": null } }
  ]
}
```

- Weekly is `seven_day_oauth_apps` if it is a non-empty object, else `seven_day`. Session is
  `five_hour`.
- Scale: if any bucket `utilization` or entry `percent` is ≥ 1, every value is a percentage and is
  divided by 100. Otherwise values are fractions. Results are capped at 1.0, and negative or
  unparseable values drop the limit.
- `resets_at`: an all-digit value is epoch seconds (or milliseconds if ≥ 1e12) and is rewritten as
  ISO 8601 UTC. An ISO string is kept. Anything else passes through unchanged.
- Output limits, in order: `Session (5-hour)`, `Weekly (7-day)`, then each `limits[]` entry with
  a model scope. For those, the label and title are `<display_name or id> <Weekly|Session|Monthly>`,
  and each (model, kind) pair is kept once.

Example payload with its exact expected output: `source/test/shell.d/agent-usage-claude-limits-test.sh`.

## Outcomes and panel text (`probe_limits`, `collect_limits`)

| Case | `usageStatusText` | `authHelpText` |
|---|---|---|
| No token | `Waiting for auth` | ``Run `claude auth login` to restore authoritative usage.`` |
| `expiresAt` passed | `Sign-in expired` | ``Claude Code's saved sign-in expired[ — showing the last known limits]. Start Claude Code, or run `claude auth login`, to refresh it.`` |
| HTTP 429 | `Claude limits unavailable`* | `Anthropic's usage endpoint is rate limiting checks right now[ (retry after Ns)]. Local Claude Code stats are still shown.` |
| Other HTTP error (e.g. 401) | `Claude limits unavailable`* | `Anthropic's usage endpoint returned status N. Local Claude Code stats are still shown.` |
| No response, or a body that isn't JSON | `Claude limits unavailable`* | `Couldn't reach Anthropic's usage endpoint. Retrying shortly. Local Claude Code stats are still shown.` and `retryAdvised: true` |
| 2xx with no usable limits | `Claude limits unavailable`* | `Anthropic's usage endpoint returned no limits. Local Claude Code stats are still shown.` |

\* Only when there are no cached limits. When the last successful probe's limits still have an
open window (`resetsAt` in the future, empty, or unparseable), those limits are shown instead and
the status stays empty.

A successful probe is cached (`fetchedAtMs`, `limits`) and reused for 15 s
(`PROBE_MIN_INTERVAL_SECONDS`) unless the refresh was forced.
