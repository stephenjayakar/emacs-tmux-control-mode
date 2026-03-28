;;; tmux-cc-emacsclient.el --- emacsclient integration test -*- lexical-binding: t; -*-

(require 'cl-lib)

(let ((root (expand-file-name ".." (file-name-directory load-file-name))))
  (add-to-list 'load-path root)
  (load-file (expand-file-name "tmux-cc.el" root)))

(require 'tmux-cc)

(defun tmux-cc-test--wait (&optional rounds)
  "Wait for tmux control-mode output for ROUNDS iterations."
  (dotimes (_ (or rounds 20))
    (when (process-live-p tmux-cc-process)
      (accept-process-output tmux-cc-process 0.1))))

(defun tmux-cc-test--assert (condition fmt &rest args)
  "Signal an error unless CONDITION is non-nil using FMT and ARGS."
  (unless condition
    (error (apply #'format fmt args))))

(defun tmux-cc-test--pane-windows ()
  "Return live windows currently showing tmux pane buffers."
  (cl-remove-if-not
   (lambda (window)
     (with-current-buffer (window-buffer window)
       (and (derived-mode-p 'term-mode)
            (tmux-cc--current-pane-id))))
   (window-list)))

(defun tmux-cc-test--select-pane-window (&optional index)
  "Select pane window at INDEX from current pane windows.
Defaults to the first pane window."
  (let* ((windows (tmux-cc-test--pane-windows))
         (window (nth (or index 0) windows)))
    (tmux-cc-test--assert window "No tmux pane window is currently visible")
    (select-window window)
    window))

(defun tmux-cc-test-run-emacsclient ()
  "Exercise the tmux-cc public flows inside a live Emacs server."
  (let* ((socket "tmux-cc-emacsclient")
         (window-config (current-window-configuration))
         (old-completing-read (symbol-function 'completing-read)))
    (unwind-protect
        (progn
          (ignore-errors
            (when (process-live-p tmux-cc-process)
              (delete-process tmux-cc-process)))
          (ignore-errors
            (call-process "tmux" nil nil nil "-L" socket "kill-server"))
          (unless (hash-table-p tmux-cc-panes)
            (setq tmux-cc-panes (make-hash-table :test 'equal)))

          (tmux-cc-start
           (format "tmux -L %s -CC -f /dev/null new-session -A -s ccflow" socket))
          (tmux-cc-test--wait 30)
          (tmux-cc-test--assert (process-live-p tmux-cc-process) "start failed")

          (tmux-cc-command "display-message started")
          (tmux-cc-test--wait 10)

          (tmux-cc-send-command "split-window -h")
          (tmux-cc-test--wait 20)
          (tmux-cc-test--assert (> (length (window-list)) 1)
                                "horizontal split did not create extra window")
          (tmux-cc-test--assert (>= (hash-table-count tmux-cc-panes) 2)
                                "no pane buffers after first split")
          (tmux-cc-test--select-pane-window 0)
          (let ((before (window-buffer (selected-window))))
            (tmux-cc-focus-right)
            (tmux-cc-test--wait 10)
            (tmux-cc-test--assert
             (or (not (eq before (window-buffer (selected-window))))
                 (> (length (tmux-cc-test--pane-windows)) 1))
             "focus-right did not keep pane navigation in a tmux pane context"))
          (tmux-cc-test--select-pane-window 0)
          (tmux-cc-focus-left)
          (tmux-cc-test--wait 10)

          (tmux-cc-test--select-pane-window 0)
          (tmux-cc-send-command "split-window -v")
          (tmux-cc-test--wait 20)
          (tmux-cc-test--assert (> (length (window-list)) 2)
                                "vertical split did not create extra window")
          (tmux-cc-test--select-pane-window 0)
          (tmux-cc-focus-down)
          (tmux-cc-test--wait 10)
          (tmux-cc-test--select-pane-window 0)
          (tmux-cc-focus-up)
          (tmux-cc-test--wait 10)
          (tmux-cc-test--select-pane-window 0)
          (tmux-cc-focus-next-pane)
          (tmux-cc-test--wait 10)

          (tmux-cc-send-command "new-window -n flow-win")
          (tmux-cc-test--wait 20)
          (fset 'completing-read (lambda (&rest _) "ccflow:flow-win"))
          (tmux-cc-switch-window)
          (tmux-cc-test--wait 30)

          (tmux-cc-send-command "new-session -d -s ccflow-2")
          (tmux-cc-test--wait 20)
          (fset 'completing-read (lambda (&rest _) "ccflow-2"))
          (tmux-cc-switch-session)
          (tmux-cc-test--wait 30)
          (fset 'completing-read old-completing-read)

          (tmux-cc-manager)
          (tmux-cc-test--wait 20)
          (with-current-buffer tmux-cc-manager-buffer-name
            (tmux-cc-test--assert (search-forward "Windows" nil t)
                                  "manager missing Windows section")
            (goto-char (point-min))
            (search-forward "Panes")
            (forward-line 1)
            (tmux-cc-manager-visit))
          (tmux-cc-test--wait 20)
          (with-current-buffer tmux-cc-manager-buffer-name
            (tmux-cc-manager-refresh))
          (tmux-cc-test--wait 20)

          (tmux-cc-detach)
          (tmux-cc-test--wait 20)
          (tmux-cc-test--assert (not (process-live-p tmux-cc-process))
                                "detach did not stop the tmux control process")
          "ok")
      (ignore-errors
        (fset 'completing-read old-completing-read))
      (ignore-errors
        (set-window-configuration window-config))
      (ignore-errors
        (when (process-live-p tmux-cc-process)
          (delete-process tmux-cc-process)))
      (ignore-errors
        (call-process "tmux" nil nil nil "-L" socket "kill-server")))))

(provide 'tmux-cc-emacsclient)
;;; tmux-cc-emacsclient.el ends here
