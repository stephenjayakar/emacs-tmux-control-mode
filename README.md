# emacs-tmux-control-mode

`tmux-cc.el` integrates tmux control mode (`tmux -CC`) with Emacs.

Current scope:

- one term buffer per tmux pane
- layout updates from tmux into Emacs windows
- tmux commands from Emacs
- session and window switching
- pane split and pane kill helpers

## Install

### As a package checkout

Add the repo to `load-path` and require `tmux-cc`:

```elisp
(add-to-list 'load-path "/path/to/emacs-tmux-control-mode")
(require 'tmux-cc)
```

### As a submodule inside this config

This repo currently uses:

```elisp
(add-to-list 'load-path
             (expand-file-name "site-lisp/emacs-tmux-control-mode" user-emacs-directory))
(require 'tmux-cc)
```

## Basic usage

Start tmux control mode:

```elisp
M-x tmux-cc-start
```

The default prompt command is `tmux -CC attach`.

Typical commands:

- `tmux -CC attach`
- `tmux -CC new-session -A -s work`
- `ssh -t host tmux -CC attach`

Useful interactive commands:

- `M-x tmux-cc-start`
- `M-x tmux-cc-command`
- `M-x tmux-cc-new-window`
- `M-x tmux-cc-new-session`
- `M-x tmux-cc-switch-session`
- `M-x tmux-cc-switch-window`
- `M-x tmux-cc-manager`

Inside a pane buffer:

- normal Emacs window arrangement commands stay local to Emacs
- `C-<tab>` moves to the next visible tmux pane
- `C-S-<tab>` moves to the previous visible tmux pane
- `C-c w` opens the tmux manager
- `C-c |` splits the current tmux pane horizontally
- `C-c -` splits the current tmux pane vertically
- `C-c C-n` creates a new tmux window
- `C-c N` creates a new detached tmux session
- `C-c C-w` switches tmux windows
- `C-c C-s` switches tmux sessions
- `C-c C-d` detaches the tmux client

Inside the tmux manager:

- `RET` visits the target at point
- `TAB` previews the target pane in a side window
- `g` refreshes sessions, windows, and panes
- `h` or `?` shows the manager help buffer
- `k` kills the target at point
- `n` creates a new tmux window
- `S` creates a new detached tmux session
- `c` runs an arbitrary tmux command
- `s` and `w` switch sessions/windows
- `d` detaches the current tmux client

## Verification

Byte compile:

```bash
emacs --batch -Q -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile tmux-cc.el tests/tmux-cc-test.el
```

Run tests:

```bash
emacs --batch -Q -L . --eval "(progn (load-file \"tmux-cc.el\") (load-file \"tests/tmux-cc-test.el\") (ert-run-tests-batch-and-exit))"
```

Run live-server integration through `emacsclient`:

```bash
tests/tmux-cc-emacsclient.sh
```

Run the deterministic live e2e interface directly:

```bash
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-run)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-emacs-window-arrangement)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-vertical-tab-focus)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-preview)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-state)'
```
