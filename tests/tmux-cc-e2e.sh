#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORM="${1:-"(tmux-cc-e2e-run)"}"

emacsclient -e \
  "(progn
     (load-file \"$ROOT/tests/tmux-cc-e2e.el\")
     (unwind-protect
         $FORM
       (ignore-errors
         (tmux-cc-e2e-stop))))"
