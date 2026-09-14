# Provenance

Everything under `source/` and `theme/` is copied unmodified from
<https://github.com/basecamp/omarchy>, branch `quattro`, commit
`b679363bed05415771a1b1dc92c6899a908236f7`. Paths mirror the Omarchy repo.
Omarchy is MIT licensed; its notice is reproduced in `/LICENSE`.

- `source/shell/plugins/agents/` — the agents widget: layout, labels, thresholds, settings.
- `source/shell/Commons/`, `source/shell/Ui/` — the style tokens, colour roles, and panel chrome
  the widget renders with.
- `source/default/`, `source/bin/omarchy-theme-set-templates`, `source/install/user/theme.sh` —
  how the default theme, Hyprland rounding and gaps, popup border, and bar font are resolved.
- `source/bin/omarchy-agent-usage-*` — the collectors that write the usage records, and so the
  record contract (fields, defaults, limit labels, auth and error strings, the Claude usage request).
- `source/test/shell.d/agent*-test.sh` — Omarchy's own tests for those collectors and the panel.
- `source/shell/Ui/{Button,PanelSectionHeader,PanelSeparator,PanelToolTip,PanelKeyCatcher,OpticalGlyph,BarIndicator}.qml`
  — the controls, keys and tooltip the panel is built from.
- `source/shell/plugins/bar/Bar.qml` — the bar, including the open-panel indicator under a module.
- `source/bin/omarchy-agent` — what the bar icon's right click launches.

`screenshots/` holds captures from a real install; see its README.
- `theme/themes/tokyo-night/colors.toml` — Omarchy's default theme.
- `theme/themes/catppuccin-latte/colors.toml` — a light theme, for testing.

Still to capture from a running Omarchy install (see CLAUDE.md, Phase 0):

- `records/` — record JSON from `omarchy agent usage-update`, account identifiers scrubbed.
- `request.md` — the exact usage-endpoint HTTP call and response shape.
- `screenshots/` — the bar icon in its normal, warning and error states at a known display scale.
  (The open panel is captured: `screenshots/panel-codex.webp`.)
