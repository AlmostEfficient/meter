# Meter

<img width="265" height="148" alt="image" src="https://github.com/user-attachments/assets/12060c29-3808-4fb2-84b7-673dab730217" />

Floating macOS overlay showing AI tool usage (Claude, Cursor, Codex). Self-contained — no external dependencies beyond `swiftc` and `node`.

## Requirements

- macOS
- `swiftc` (Xcode Command Line Tools)
- `node` (ships with Claude Code, Cursor, and Codex — you already have it)

## Run

```bash
./meter.sh
```

Compiles the Swift sources on first run (or when any source changes), then launches the overlay. The panel floats above all windows, persists across Spaces, and refreshes every 60 seconds.

## Usage

- **Drag** anywhere on the panel to reposition
- **Right-click** for settings: refresh interval, display toggles, per-provider enable/disable

## Configuration

Settings are stored in `UserDefaults` under the `Meter*` key prefix and persist across restarts.

Provider icons are loaded from the installed app bundle if present, falling back to:

- `assets/codex.png`
- `assets/claude.png`
- `assets/cursor.png`
