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

Typical commands:

- `tmux -CC attach`
- `tmux -CC new-session -A -s work`
- `ssh -t host tmux -CC attach`

Useful interactive commands:

- `M-x tmux-cc-start`
- `M-x tmux-cc-command`
- `M-x tmux-cc-switch-session`
- `M-x tmux-cc-switch-window`

Inside a pane buffer:

- `split-window-right` and `split-window-below` are forwarded to tmux
- `delete-window` kills the pane
- `delete-other-windows` kills sibling panes

## Verification

Byte compile:

```bash
emacs --batch -Q -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile tmux-cc.el tests/tmux-cc-test.el
```

Run tests:

```bash
emacs --batch -Q -L . --eval "(progn (load-file \"tmux-cc.el\") (load-file \"tests/tmux-cc-test.el\") (ert-run-tests-batch-and-exit))"
```
