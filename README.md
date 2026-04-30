# Meter

<img width="265" height="148" alt="image" src="https://github.com/user-attachments/assets/12060c29-3808-4fb2-84b7-673dab730217" />

Floating macOS overlay showing AI tool usage. Also ships a CLI. Self-contained — no external dependencies beyond `swiftc` and `node`.

## Requirements

- macOS
- `swiftc` (Xcode Command Line Tools)
- `node` (ships with Claude Code, Cursor, and Codex — you already have it)

## Install

```bash
./install.sh
```

Generates a LaunchAgent from the current directory, installs it to `~/Library/LaunchAgents/`, and starts it. Meter will auto-start on login and restart if it crashes.

To restart after making changes:

```bash
launchctl stop com.$(whoami).meter && launchctl start com.$(whoami).meter
```

## How it works

`meter.sh` compiles the Swift sources on first run (or when any source changes), then launches the overlay. The panel floats above all windows, persists across Spaces, and refreshes every 60 seconds.

## Usage

- **Drag** anywhere on the panel to reposition
- **Right-click** for settings: refresh interval, display toggles, per-provider enable/disable

## Providers

| Provider | Default on | Auth |
|---|---|---|
| Codex | ✓ | `~/.codex/auth.json` |
| Claude | ✓ | Keychain / `~/.claude.json` |
| Cursor | — | `~/.config/meter/cursor-cookie` or `$CURSOR_COOKIE` |
| Crof | — | `~/.config/meter/crof` or `$CROF_SESSION` |
| OpenRouter | — | `~/.config/meter/openrouter` or `$OPENROUTER_API_KEY` |

## CLI

```bash
usage-hud                        # all providers
usage-hud claude                 # single provider
usage-hud --compact              # one-line summary
usage-hud --json                 # JSON output
usage-hud --watch                # refresh every 30s
```

Symlinked to `~/.local/bin/usage-hud`. Results are cached at `~/.cache/meter/state.json` (60s TTL).

## Configuration

Settings are stored in `UserDefaults` under the `Meter*` key prefix and persist across restarts.

Provider icons are loaded from the installed app bundle if present, falling back to `assets/<provider>.png`.
