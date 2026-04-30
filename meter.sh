#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
srcs=("$script_dir"/*.swift)
bin="/private/tmp/meter"
module_cache="/private/tmp/meter-module-cache"

needs_build=false
if [[ ! -x "$bin" ]]; then
  needs_build=true
else
  for src in "${srcs[@]}"; do
    if [[ "$src" -nt "$bin" ]]; then
      needs_build=true
      break
    fi
  done
fi

if [[ "$needs_build" == true ]]; then
  mkdir -p "$module_cache"
  /usr/bin/swiftc -module-cache-path "$module_cache" "${srcs[@]}" -o "$bin"
fi

export METER_ROOT="$script_dir"

exec "$bin"
