#!/usr/bin/env bash
# stop-all.sh - stops everything that run-all.sh started.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for f in "$ROOT"/.pids/*.pid; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .pid)"
  pid="$(cat "$f")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" && echo "stopped $name"
  else
    echo "$name was not running"
  fi
  rm -f "$f"
done
