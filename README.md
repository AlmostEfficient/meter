# Meter

<img width="265" height="148" alt="image" src="https://github.com/user-attachments/assets/12060c29-3808-4fb2-84b7-673dab730217" />


Small macOS overlay that renders `usage-hud --json` output in a floating panel.

## Requirements

- macOS
- `swiftc` (Xcode Command Line Tools)

## Run

```bash
./meter.sh
```

## Configuration

You can override the `usage-hud` command without editing source:

```bash
METER_COMMAND="$HOME/.local/bin/usage-hud" ./meter.sh
```

By default, the launcher exports:

- `METER_ROOT` (auto-detected from script location)
- `METER_COMMAND` (`usage-hud` unless overridden)

The app looks for local fallback icons in:

- `assets/codex.png`
- `assets/claude.png`
- `assets/cursor.png`
