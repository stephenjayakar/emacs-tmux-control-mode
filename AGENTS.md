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
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-mixed-window-navigation)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-vertical-tab-focus)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-kill-pane)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-case-preview)'
tests/tmux-cc-e2e.sh '(tmux-cc-e2e-state)'
