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
- `theme/themes/tokyo-night/colors.toml` — Omarchy's default theme.
- `theme/themes/catppuccin-latte/colors.toml` — a light theme, for testing.

Still to capture from a running Omarchy install (see CLAUDE.md, Phase 0):

- `records/` — record JSON from `omarchy agent usage-update`, account identifiers scrubbed.
- `request.md` — the exact usage-endpoint HTTP call and response shape.
- `screenshots/` — bar icon in normal, warning, and error states, and the open panel, with display scale.
