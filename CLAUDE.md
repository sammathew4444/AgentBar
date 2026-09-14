AgentBar — macOS port of Omarchy's omarchy.agents widget

A menu bar app for macOS that reproduces the interface and behaviour of the agents widget built into Omarchy Quattro: AI coding agent usage limits, with pace, today, last week, and all-time model breakdown.

Open source, MIT. Not affiliated with or endorsed by Omarchy or 37signals.

0. Ground rules for Claude Code

Paste this section into CLAUDE.md at the repo root before starting.

Hard constraints

Never write to ~/.claude/, ~/.codex/, or any agent CLI's credential store. Read only.
Never log, print, or persist an access token, not even truncated, not even in debug builds.
Network egress is limited to the provider usage endpoints. No telemetry, no analytics, no crash reporting.
If a token is expired or missing, render a re-auth state. Do not attempt a refresh flow.
Poll at 15 minutes, matching Omarchy's cadence, plus a refresh when the panel opens. The usage endpoint rate-limits. Never poll in a tight loop, including in tests.

Fidelity rule

Anything in reference/ was captured from a real Omarchy install and is ground truth. When the reference and your instincts disagree, the reference wins. Do not invent layout, labels, thresholds, or schema fields. If something needed is not in reference/, stop and say what capture is missing rather than guessing.

Stack

Swift 6, macOS 14+ minimum.
Swift Package Manager executable target, not an Xcode project. Build with swift build. A Scripts/bundle.sh assembles AgentBar.app from the built binary plus Info.plist. This keeps every step runnable from the CLI.
AppKit for the status item and panel window. SwiftUI for everything inside the panel.
No third-party dependencies.
Phase 0 — Capture ground truth (manual, on the Omarchy machine)

Do this first, by hand. Everything after it depends on it. The point is that Claude Code never has to guess what the original looks like or what the data shape is.

Create reference/ in the repo and fill it:

reference/source/ — copy of $OMARCHY_PATH/shell/plugins/agents/, including the README and the QML. This is the layout spec, the label strings, the colour thresholds, and the settings list.
reference/records/ — run omarchy agent usage-update, then copy the generated record JSON files. One per provider if you have more than one configured. Redact nothing structural, but scrub any account identifiers before committing.
reference/request.md — from the collector source, write down the exact HTTP call: URL, method, every header including any beta/version header, and the response shape. Do not rely on memory or blog posts for this.
reference/screenshots/ — the bar icon in its normal, warning, and error states, and the panel open, at a known display scale. Note the scale in a caption file.
reference/theme/ — copy of ~/.config/omarchy/current/theme/colors.toml for the theme you use, plus one more theme for testing.

Acceptance: someone with no Omarchy machine could rebuild the widget from reference/ alone.

Phase 1 — Status item and panel shell

Goal: an app that launches, shows a glyph in the menu bar, and opens an empty panel that looks right.

SPM package, executable target AgentBar, Scripts/bundle.sh, Info.plist with LSUIElement = true.
NSStatusItem with variable length. Button configured with sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp]), branching on NSApp.currentEvent?.type. Scroll handler too, as the trackpad-friendly substitute for middle click.
Panel is a borderless, non-activating NSPanel at .statusBar window level hosting an NSHostingView, positioned under the status item, dismissed on resign-key and on outside click. Not NSPopover — its arrow, vibrancy and corner radius fight the Omarchy look.
Bundle the Nerd Font used by Omarchy's bar and its OFL licence file. Use the font's robot glyph for the bar icon.

Acceptance: swift build && ./Scripts/bundle.sh && open AgentBar.app puts a glyph in the menu bar; left click toggles a panel with placeholder content; right and middle click log distinct no-op actions; no Dock icon.

Phase 2 — Record model and store

Goal: the Omarchy record contract, modelled in Swift, loaded from disk.

Codable types for the record schema. Per reference/records/, this is schemaVersion, id, name, updatedAt, ready, tierLabel, usageStatusText, authHelpText, limits[] of { title, percent (0.0–1.0), resetsAt, used, allowance }, and balance for prepaid plans. Confirm every field against the captured records; the reference is authoritative over this list.
Store reads and writes ~/Library/Application Support/AgentBar/records/<id>.json. Same schema on disk as Omarchy uses, deliberately, so collector scripts from the Omarchy ecosystem can be pointed at this directory and just work.
Decode every file in reference/records/ in a test. Add a malformed-input test and an unknown-schemaVersion test that degrades gracefully rather than crashing.

Acceptance: tests pass against the real captured records, with no network access in the test suite.

Phase 3 — Claude Code collector

Goal: real numbers in the bar.

Read the OAuth token by shelling out to /usr/bin/security find-generic-password for the Claude Code-credentials item. Shelling out means the Keychain prompt is attributed to the system binary, and the user's "Always Allow" decision is revocable in Keychain Access. Handle the deny and not-found cases as distinct states.
Issue exactly the request captured in reference/request.md. Map the response into a record and write it through the store.
Handle: no Claude Code installed, not logged in, token expired (401), rate limited (429), offline. Each maps to a specific panel state with the right help text. Cached records stay visible and are marked stale rather than being blanked.
Refresh timer at 15 minutes plus on panel open, with a floor so rapid open/close can't hammer the endpoint.

Acceptance: the bar shows your real session percentage and it matches what /usage reports in Claude Code. Pull the network cable and the last value stays, marked stale.

Phase 4 — Panel UI

Goal: the panel matches reference/screenshots/.

Build against the captured QML: same rows, same ordering, same label strings, same percentage formatting, same reset-time formatting.
Bar icon: percentage plus colour thresholds exactly as the reference defines them. Use an attributed title on the status item button so the colour shows in the menu bar.
Right click launches your configured agent, via NSWorkspace opening your terminal with the agent command. Configurable, defaulting to claude.
Middle click and scroll cycle subscriptions when more than one record exists.

Acceptance: side-by-side with reference/screenshots/, differences are only those forced by macOS (system font rendering, menu bar height).

Phase 5 — Codex and the model breakdown
Codex collector reading ~/.codex/auth.json, producing a record with the same schema. Same expired-token handling; on 401 the panel says to re-run codex, and falls back to the most recent local session data, clearly marked as lagging.
Token usage by day and by model, parsed from local session logs under ~/.claude/projects/**/*.jsonl. This is purely local, no network.
Pace, today, last week, all-time views, as the reference defines them.

Acceptance: both providers render; cycling between them works; the breakdown numbers are reproducible from a fixture set of JSONL files committed to the repo.

Phase 6 — Theming and settings
Parse colors.toml in the Omarchy theme format. Point the app at an Omarchy theme directory and the panel matches that theme. Ship a sensible default for people with no Omarchy install. Test against both themes in reference/theme/.
Settings: agent launch command, refresh interval, show-percentage-in-bar toggle, records directory, optional synced-folder path for merging usage from other machines (the Omarchy feature — read foreign records from a folder and merge by id and updatedAt).
Launch at login via SMAppService.mainApp.register().
Phase 7 — Distribution
Do not sandbox. The app needs ~/.claude and ~/.codex. That rules out the App Store, which is fine.
Developer ID signing, hardened runtime, notarization, stapled ticket. Without this Gatekeeper will block every user who isn't you.
Scripts/release.sh: build, bundle, sign, notarize, staple, zip, checksum.
GitHub Releases plus a Homebrew cask.
CI: build and test on every push. Signing secrets stay out of PR builds.
Phase 8 — Repo hygiene
LICENSE: your MIT notice, plus a section "Portions derived from Omarchy (MIT), Copyright (c) 37signals" with their full notice reproduced beneath it. Same pattern the OmaMenu clone uses in the Omarchy marketplace.
README.md opening lines:

A macOS menu bar port of Omarchy's built-in agents widget. Same interface, same behaviour, because I missed it on my Mac.

Not affiliated with or endorsed by Omarchy or 37signals.

SECURITY.md stating plainly what the app reads, what it sends, and where.
Screenshot in the README showing the Mac panel next to the Omarchy original.
Your own app icon. Not Omarchy's logo.