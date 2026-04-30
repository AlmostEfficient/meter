# Meter

  
<img width="272" height="358" alt="image" src="https://github.com/user-attachments/assets/2838d8d4-a398-4490-9a16-29f7d9e9d2e1" />
  

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
| Codex Plus/Pro | ✓ | `~/.codex/auth.json` |
| Claude Pro/Max | ✓ | Keychain / `~/.claude.json` |
| Cursor Pro/Ultra | — | `~/.config/meter/cursor-cookie` or `$CURSOR_COOKIE` |
| Crof | — | `~/.config/meter/crof` or `$CROF_SESSION` |
| OpenRouter | — | `~/.config/meter/openrouter` or `$OPENROUTER_API_KEY` |
| OpenAI (API) | — | `~/.config/meter/openai` or `$OPENAI_ADMIN_KEY` or Keychain |
| Anthropic (API) | — | Keychain (preferred) or `~/.config/meter/anthropic` or `$ANTHROPIC_ADMIN_KEY` |

### OpenAI & Anthropic admin keys

Both providers require an **admin API key** (not a regular API key) to access spending data.

**OpenAI:** Get one at [platform.openai.com → Organization → Admin Keys](https://platform.openai.com/settings/organization/admin-keys). Save it to `~/.config/meter/openai`. Read only is fine. 

**Anthropic:** Requires an organization account (Console → Settings → Organization). Once set up, create an admin key at Console → Settings → Admin Keys — it starts with `sk-ant-admin...`.

Because the Anthropic admin key has broad org-level write access, store it in the Keychain rather than a flat file:

1. Open **Keychain Access** → File → New Password Item
2. Set **Keychain Item Name** and **Account Name** both to `meter-claude-admin-key`
3. Paste the key as the password and click **Add**
4. When macOS prompts on first run, click **Always Allow** so Meter can read it without prompting every refresh.

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
