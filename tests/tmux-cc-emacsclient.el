;;; tmux-cc-emacsclient.el --- compatibility wrapper -*- lexical-binding: t; -*-

(declare-function tmux-cc-e2e-run "tmux-cc-e2e")

(let ((root (expand-file-name ".." (file-name-directory load-file-name))))
  (load-file (expand-file-name "tests/tmux-cc-e2e.el" root)))

(defun tmux-cc-test-run-emacsclient ()
  "Run the live tmux-cc emacsclient suite."
  (tmux-cc-e2e-run))

(provide 'tmux-cc-emacsclient)
;;; tmux-cc-emacsclient.el ends here
