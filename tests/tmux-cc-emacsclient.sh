#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

result="$("$ROOT/tests/tmux-cc-e2e.sh")"

if [[ "$result" != "\"ok\"" ]]; then
  echo "tmux-cc emacsclient integration test failed: $result" >&2
  exit 1
fi

echo "ok"
