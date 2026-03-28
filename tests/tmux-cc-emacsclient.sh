#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

result="$(
  emacsclient --eval \
    "(progn
       (load-file \"$ROOT/tests/tmux-cc-emacsclient.el\")
       (tmux-cc-test-run-emacsclient))"
)"

if [[ "$result" != "\"ok\"" ]]; then
  echo "tmux-cc emacsclient integration test failed: $result" >&2
  exit 1
fi

echo "ok"
