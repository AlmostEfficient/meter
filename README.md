# Meter

<img width="265" height="148" alt="image" src="https://github.com/user-attachments/assets/12060c29-3808-4fb2-84b7-673dab730217" />

Floating macOS overlay showing AI tool usage (Claude, Cursor, Codex) from `usage-hud`.

## Requirements

- macOS
- `swiftc` (Xcode Command Line Tools)
- [`usage-hud`](https://github.com/nicholasgasior/usage-hud) on your PATH

## Run

```bash
./meter.sh
```

Compiles `Meter.swift` on first run (or when the source changes), then launches the overlay. The panel floats above all windows, persists across Spaces, and refreshes every 60 seconds.

## Usage

- **Drag** anywhere on the panel to reposition
- **Right-click** for settings: refresh interval, display toggles, per-provider enable/disable

## Configuration

Override the backend command without editing source:

```bash
METER_COMMAND="$HOME/.local/bin/usage-hud" ./meter.sh
```

Settings are stored in `UserDefaults` under the `Meter*` key prefix and persist across restarts.

Provider icons are loaded from the installed app bundle if present, falling back to:

- `assets/codex.png`
- `assets/claude.png`
- `assets/cursor.png`
