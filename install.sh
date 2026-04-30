#!/bin/zsh
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
plist="$HOME/Library/LaunchAgents/com.$(whoami).meter.plist"
bin_dir="$HOME/.local/bin"
cli_link="$bin_dir/usage-hud"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.$(whoami).meter</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$dir/meter.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$dir</string>
    <key>StandardOutPath</key>
    <string>/tmp/meter.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/meter.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

launchctl unload "$plist" 2>/dev/null || true
launchctl load "$plist"
mkdir -p "$bin_dir"
ln -sf "$dir/cli/usage-hud.js" "$cli_link"
echo "Meter installed and running. Label: com.$(whoami).meter"
echo "CLI installed: $cli_link"
