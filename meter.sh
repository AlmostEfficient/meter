#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
src="$script_dir/Meter.swift"
bin="/private/tmp/meter"
module_cache="/private/tmp/meter-module-cache"

if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
  mkdir -p "$module_cache"
  /usr/bin/swiftc -module-cache-path "$module_cache" "$src" -o "$bin"
fi

export METER_ROOT="$script_dir"

exec "$bin"
