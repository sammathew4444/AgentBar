# AgentBar

A macOS menu bar port of Omarchy's built-in agents widget. Same interface, same behaviour, because I missed it on my Mac.

Not affiliated with or endorsed by Omarchy or 37signals.

## Status

Early work in progress. The menu bar glyph and the themed panel shell work; usage data is not wired up yet.
See `CLAUDE.md` for the phased plan.

## Build

Requires macOS 14+ and Swift 6.

```sh
swift build && ./Scripts/bundle.sh && open AgentBar.app
```

## Reference

`reference/` holds the Omarchy sources this port is built against, pinned to a specific commit.
See `reference/PROVENANCE.md`.

## License

MIT. Portions derived from Omarchy (MIT). See `LICENSE`.
