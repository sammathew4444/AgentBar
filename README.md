# AgentBar

A macOS menu bar port of Omarchy's built-in agents widget. Same interface, same behaviour, because I missed it on my Mac.

Not affiliated with or endorsed by Omarchy or 37signals.

## What it shows

A robot in the menu bar opens a panel with, for each AI coding agent you use:

- Its usage limits (session, weekly, model-scoped), with reset countdowns
- Tokens by day for the last week, and tokens by model
- Claude Code, Codex and Grok, read from their local files, with Claude's and Codex's limits from
  their own sources

It follows Omarchy's look, defaulting to Tokyo Night, with all of Omarchy's themes one click away.
It can also merge usage from other machines through a synced folder, in Omarchy's own format.

## Try it

AgentBar is a hobby project published here for anyone who wants to try it. It needs macOS 14 or
later.

**Download:** grab `AgentBar-<version>.zip` from [Releases](https://github.com/sammathew4444/AgentBar/releases),
unzip it and move `AgentBar.app` to Applications. The app isn't signed or notarized, so macOS
won't open it the first time. Allow it in System Settings › Privacy & Security › Open Anyway, or
run:

```sh
xattr -dr com.apple.quarantine /Applications/AgentBar.app
```

**Build from source:** with Swift 6 (Xcode 16 or later):

```sh
swift build && ./Scripts/bundle.sh && open AgentBar.app
```

## Using it

- Left click the robot: open the panel. Right click: open Terminal with your agent (`claude` by default).
- Middle click or scroll on the robot, or h/l in the panel: switch agents. r refreshes, Esc closes.
- The palette button picks a theme; the gear opens settings.

## Reference

`reference/` holds the Omarchy sources this port is built against, pinned to a specific commit.
See `reference/PROVENANCE.md`. Releasing is described in `docs/RELEASING.md`.

## License

MIT. Portions derived from Omarchy (MIT). See `LICENSE`.
