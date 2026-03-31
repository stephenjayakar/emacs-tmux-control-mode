;;; tmux-cc-e2e.el --- live emacsclient e2e interface -*- lexical-binding: t; -*-

(require 'cl-lib)

(let ((root (expand-file-name ".." (file-name-directory load-file-name))))
  (add-to-list 'load-path root)
  (load-file (expand-file-name "tmux-cc.el" root)))

(require 'tmux-cc)

(defconst tmux-cc-e2e-socket "tmux-cc-e2e")
(defconst tmux-cc-e2e-session "ccflow")
(defconst tmux-cc-e2e-window-name "flow-win")
(defconst tmux-cc-e2e-session-2 "ccflow-2")

(defun tmux-cc-e2e--wait (&optional rounds)
  "Wait for tmux control-mode output for ROUNDS iterations."
  (dotimes (_ (or rounds 30))
    (when (process-live-p tmux-cc-process)
      (accept-process-output tmux-cc-process 0.1))))

(defun tmux-cc-e2e--wait-until (predicate description &optional rounds)
  "Wait until PREDICATE returns non-nil or fail with DESCRIPTION."
  (let (result)
    (dotimes (_ (or rounds 80))
      (unless result
        (setq result (funcall predicate))
        (unless result
          (tmux-cc-e2e--wait 1))))
    (tmux-cc-e2e--assert result "%s" description)
    result))

(defun tmux-cc-e2e--assert (condition fmt &rest args)
  "Signal an error unless CONDITION is non-nil using FMT and ARGS."
  (unless condition
    (error "%s" (apply #'format fmt args))))

(defun tmux-cc-e2e-send-command (command &optional rounds)
  "Run tmux COMMAND and wait for command output to complete."
  (let (done result)
    (tmux-cc-send-command
     command
     (lambda (lines)
       (setq result lines
             done t)))
    (dotimes (_ (or rounds 40))
      (unless done
        (tmux-cc-e2e--wait 1)))
    (tmux-cc-e2e--assert done "tmux command did not complete: %s" command)
    result))

(defun tmux-cc-e2e-reset ()
  "Reset the live tmux-cc state used by the e2e suite."
  (interactive)
  (ignore-errors
    (tmux-cc-manager-hide-preview))
  (ignore-errors
    (when (process-live-p tmux-cc-process)
      (delete-process tmux-cc-process)))
  (ignore-errors
    (call-process "tmux" nil nil nil "-L" tmux-cc-e2e-socket "kill-server"))
  (setq tmux-cc--cmd-queue nil
        tmux-cc--buffer ""
        tmux-cc--current-cmd-lines nil
        tmux-cc--in-cmd nil
        tmux-cc-confirm-destructive-actions nil)
  (unless (hash-table-p tmux-cc-panes)
    (setq tmux-cc-panes (make-hash-table :test 'equal)))
  (maphash
   (lambda (_pane-id buffer)
     (when (buffer-live-p buffer)
       (when-let ((proc (get-buffer-process buffer)))
         (delete-process proc))
       (kill-buffer buffer)))
   tmux-cc-panes)
  (clrhash tmux-cc-panes)
  "reset")

(defun tmux-cc-e2e-start ()
  "Start a deterministic tmux-cc session for e2e tests."
  (interactive)
  (tmux-cc-e2e-reset)
  (tmux-cc-start
   (format "tmux -L %s -CC -f /dev/null new-session -A -s %s"
           tmux-cc-e2e-socket
           tmux-cc-e2e-session))
  (tmux-cc-e2e--wait-until
   (lambda ()
     (and (process-live-p tmux-cc-process)
          (> (hash-table-count tmux-cc-panes) 0)))
   "tmux-cc process failed to start")
  (tmux-cc-e2e--wait-until #'tmux-cc-e2e--manager-ready-p
                           "manager did not render sessions")
  (tmux-cc-e2e--assert (process-live-p tmux-cc-process) "tmux-cc process failed to start")
  (tmux-cc-e2e--assert
   (string= (buffer-name (window-buffer (selected-window))) tmux-cc-manager-buffer-name)
   "manager did not open first")
  (tmux-cc-e2e--assert (> (hash-table-count tmux-cc-panes) 0)
                        "pane buffers were not bootstrapped")
  "started")

(defun tmux-cc-e2e-stop ()
  "Stop the deterministic tmux-cc session."
  (interactive)
  (tmux-cc-e2e-reset)
  "stopped")

(defun tmux-cc-e2e-state ()
  "Return a plist describing the current live tmux-cc state."
  (list :process-live (process-live-p tmux-cc-process)
        :selected-buffer (buffer-name (window-buffer (selected-window)))
        :pane-count (hash-table-count tmux-cc-panes)
        :preview-window (and (window-live-p tmux-cc--manager-preview-window) t)
        :preview-buffer (and (window-live-p tmux-cc--manager-preview-window)
                             (buffer-name (window-buffer tmux-cc--manager-preview-window)))))

(defun tmux-cc-e2e--manager-ready-p ()
  "Return non-nil when the tmux manager has rendered at least one target."
  (and (buffer-live-p (get-buffer tmux-cc-manager-buffer-name))
       (with-current-buffer tmux-cc-manager-buffer-name
         (save-excursion
           (goto-char (point-min))
           (let (found)
             (while (and (not found) (< (point) (point-max)))
               (pcase-let ((`(,target-type ,_target-id ,_pane-id ,_label)
                            (tmux-cc--manager-line-target)))
                 (when target-type
                   (setq found t)))
               (unless found
                 (forward-line 1)))
             found)))))

(defun tmux-cc-e2e-manager-open ()
  "Open and refresh the tmux manager."
  (interactive)
  (tmux-cc-manager)
  (tmux-cc-e2e--wait-until #'tmux-cc-e2e--manager-ready-p
                           "manager did not render sessions")
  tmux-cc-manager-buffer-name)

(defun tmux-cc-e2e-manager-targets ()
  "Return manager targets as a list of plists."
  (tmux-cc-e2e-manager-open)
  (with-current-buffer tmux-cc-manager-buffer-name
    (goto-char (point-min))
    (let (targets)
      (while (< (point) (point-max))
        (pcase-let ((`(,target-type ,target-id ,pane-id ,label)
                     (tmux-cc--manager-line-target)))
          (when target-type
            (push (list :type target-type
                        :id target-id
                        :pane pane-id
                        :label label
                        :line (string-trim (buffer-substring-no-properties
                                            (line-beginning-position)
                                            (line-end-position))))
                  targets)))
        (forward-line 1))
      (nreverse targets))))

(defun tmux-cc-e2e--manager-goto (predicate description)
  "Move point to the first manager line matching PREDICATE for DESCRIPTION."
  (tmux-cc-e2e-manager-open)
  (with-current-buffer tmux-cc-manager-buffer-name
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (< (point) (point-max)))
        (pcase-let ((`(,target-type ,target-id ,pane-id ,label)
                     (tmux-cc--manager-line-target)))
          (when (and target-type
                     (funcall predicate target-type target-id pane-id label))
            (setq found (point))))
        (unless found
          (forward-line 1)))
      (tmux-cc-e2e--assert found "No manager target matched: %s" description)
      (goto-char found)
      found)))

(defun tmux-cc-e2e-manager-goto-id (target-type target-id)
  "Move point to TARGET-TYPE/TARGET-ID in the manager."
  (tmux-cc-e2e--manager-goto
   (lambda (type id _pane-id _label)
     (and (eq type target-type)
          (equal id target-id)))
   (format "%s %s" target-type target-id)))

(defun tmux-cc-e2e-manager-goto-label (target-type label-substring)
  "Move point to TARGET-TYPE with LABEL-SUBSTRING in the manager."
  (tmux-cc-e2e--manager-goto
   (lambda (type _id _pane-id label)
     (and (eq type target-type)
          label
          (string-match-p (regexp-quote label-substring) label)))
   (format "%s label %s" target-type label-substring)))

(defun tmux-cc-e2e-manager-preview-id (target-type target-id)
  "Preview TARGET-TYPE/TARGET-ID from the manager and return the preview buffer."
  (tmux-cc-e2e-manager-goto-id target-type target-id)
  (with-current-buffer tmux-cc-manager-buffer-name
    (tmux-cc-manager-toggle-preview))
  (tmux-cc-e2e--wait 5)
  (tmux-cc-e2e--assert (window-live-p tmux-cc--manager-preview-window)
                        "Preview window did not open for %s %s" target-type target-id)
  (buffer-name (window-buffer tmux-cc--manager-preview-window)))

(defun tmux-cc-e2e-manager-visit-id (target-type target-id)
  "Visit TARGET-TYPE/TARGET-ID from the manager and return the selected buffer."
  (tmux-cc-e2e-manager-goto-id target-type target-id)
  (with-current-buffer tmux-cc-manager-buffer-name
    (tmux-cc-manager-visit))
  (tmux-cc-e2e--wait 20)
  (buffer-name (window-buffer (selected-window))))

(defun tmux-cc-e2e-manager-delete-id (target-type target-id)
  "Delete TARGET-TYPE/TARGET-ID from the manager."
  (tmux-cc-e2e-manager-goto-id target-type target-id)
  (with-current-buffer tmux-cc-manager-buffer-name
    (tmux-cc-manager-delete))
  (tmux-cc-e2e--wait 30)
  (tmux-cc-e2e-manager-targets))

(defun tmux-cc-e2e--visit-first-pane ()
  "Visit the first tracked tmux pane."
  (let (pane-id)
    (maphash (lambda (key _buffer)
               (unless pane-id
                 (setq pane-id key)))
             tmux-cc-panes)
    (tmux-cc-e2e--assert pane-id "No tmux panes are tracked")
    (tmux-cc--display-pane-buffer pane-id)
    (tmux-cc-e2e--wait 10)
    pane-id))

(defun tmux-cc-e2e--visible-pane-id ()
  "Return the pane id associated with the selected window buffer."
  (with-current-buffer (window-buffer (selected-window))
    (tmux-cc--current-pane-id)))

(defun tmux-cc-e2e-test-start ()
  "Verify startup and manager rendering."
  (tmux-cc-e2e-start)
  (let ((targets (tmux-cc-e2e-manager-targets)))
    (tmux-cc-e2e--assert (cl-find-if (lambda (item) (eq (plist-get item :type) 'session)) targets)
                          "manager did not render sessions")
    (tmux-cc-e2e--assert (cl-find-if (lambda (item) (eq (plist-get item :type) 'window)) targets)
                          "manager did not render windows")
    (tmux-cc-e2e--assert (cl-find-if (lambda (item) (eq (plist-get item :type) 'pane)) targets)
                          "manager did not render panes"))
  "ok-start")

(defun tmux-cc-e2e-test-command ()
  "Verify arbitrary tmux command execution."
  (tmux-cc-command "display-message e2e-started")
  (tmux-cc-e2e--wait 10)
  "ok-command")

(defun tmux-cc-e2e-test-preview ()
  "Verify manager preview for both a window and a pane."
  (let* ((targets (tmux-cc-e2e-manager-targets))
         (window-id (plist-get (cl-find-if (lambda (item) (eq (plist-get item :type) 'window))
                                           targets)
                               :id))
         (pane-id (plist-get (cl-find-if (lambda (item) (eq (plist-get item :type) 'pane))
                                         targets)
                             :id)))
    (tmux-cc-e2e--assert window-id "No window target available for preview")
    (tmux-cc-e2e--assert pane-id "No pane target available for preview")
    (tmux-cc-e2e--assert
     (string-prefix-p tmux-cc-pane-buffer-prefix
                      (tmux-cc-e2e-manager-preview-id 'window window-id))
     "Window preview did not show a pane buffer")
    (tmux-cc-e2e-manager-goto-id 'pane pane-id)
    (with-current-buffer tmux-cc-manager-buffer-name
      (tmux-cc-manager-toggle-preview))
    (tmux-cc-e2e--wait 5)
    (tmux-cc-e2e--assert (not (window-live-p tmux-cc--manager-preview-window))
                          "Preview toggle did not close the active preview"))
  "ok-preview")

(defun tmux-cc-e2e-test-help ()
  "Verify manager help buffer."
  (tmux-cc-e2e-manager-open)
  (with-current-buffer tmux-cc-manager-buffer-name
    (tmux-cc-manager-help))
  (tmux-cc-e2e--assert (get-buffer tmux-cc-manager-help-buffer-name)
                        "Manager help buffer did not open")
  "ok-help")

(defun tmux-cc-e2e-test-splits-and-focus ()
  "Verify pane splits and focus movement."
  (tmux-cc-e2e--visit-first-pane)
  (let ((initial-pane (tmux-cc-e2e--visible-pane-id)))
    (tmux-cc-split-horizontal)
    (tmux-cc-e2e--wait 20)
    (tmux-cc-e2e--assert (>= (hash-table-count tmux-cc-panes) 2)
                          "Horizontal split did not add a pane")
    (tmux-cc-focus-right)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-focus-left)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-split-vertical)
    (tmux-cc-e2e--wait 20)
    (tmux-cc-e2e--assert (>= (hash-table-count tmux-cc-panes) 3)
                          "Vertical split did not add a pane")
    (tmux-cc-focus-down)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-focus-up)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-focus-next-pane)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-e2e--assert initial-pane "No initial pane was visible"))
  "ok-splits-focus")

(defun tmux-cc-e2e-test-vertical-tab-focus ()
  "Verify next/previous pane cycling works for vertical tiling."
  (tmux-cc-e2e--visit-first-pane)
  (let ((initial-pane (tmux-cc-e2e--visible-pane-id)))
    (tmux-cc-split-vertical)
    (tmux-cc-e2e--wait 20)
    (tmux-cc-e2e--assert (>= (hash-table-count tmux-cc-panes) 2)
                          "Vertical split did not add a second pane")
    (tmux-cc-focus-next-pane)
    (tmux-cc-e2e--wait 10)
    (let ((next-pane (tmux-cc-e2e--visible-pane-id)))
      (tmux-cc-e2e--assert (and next-pane (not (equal next-pane initial-pane)))
                            "Next-pane did not move off the original vertical pane")
      (tmux-cc-focus-previous-pane)
      (tmux-cc-e2e--wait 10)
      (tmux-cc-e2e--assert (equal (tmux-cc-e2e--visible-pane-id) initial-pane)
                            "Previous-pane did not return to the original vertical pane")))
  "ok-vertical-tab-focus")

(defun tmux-cc-e2e-test-kill-pane ()
  "Verify killing a pane removes both the tmux pane and its Emacs buffer."
  (tmux-cc-e2e--visit-first-pane)
  (tmux-cc-split-horizontal)
  (tmux-cc-e2e--wait 20)
  (tmux-cc-focus-next-pane)
  (tmux-cc-e2e--wait 10)
  (let* ((pane-id (tmux-cc-e2e--visible-pane-id))
         (buffer (window-buffer (selected-window))))
    (tmux-cc-e2e--assert pane-id "No pane selected for kill-pane test")
    (tmux-cc-kill-pane pane-id)
    (tmux-cc-e2e--wait 20)
    (tmux-cc-e2e--assert (not (buffer-live-p buffer))
                          "Killed pane buffer is still live")
    (tmux-cc-e2e--assert (not (gethash pane-id tmux-cc-panes))
                          "Killed pane is still tracked"))
  "ok-kill-pane")

(defun tmux-cc-e2e-test-emacs-window-arrangement ()
  "Verify normal Emacs window arrangement stays local."
  (tmux-cc-e2e--visit-first-pane)
  (let ((initial-pane-count (hash-table-count tmux-cc-panes))
        (initial-window-count (count-windows)))
    (split-window-right)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-e2e--assert (= (hash-table-count tmux-cc-panes) initial-pane-count)
                          "Emacs split-window-right incorrectly created a tmux pane")
    (tmux-cc-e2e--assert (> (count-windows) initial-window-count)
                          "Emacs split-window-right did not create an Emacs window")
    (delete-window)
    (tmux-cc-e2e--wait 10)
    (tmux-cc-e2e--assert (= (hash-table-count tmux-cc-panes) initial-pane-count)
                          "Deleting an Emacs window incorrectly killed a tmux pane"))
  "ok-emacs-window-arrangement")

(defun tmux-cc-e2e-test-mixed-window-navigation ()
  "Verify smart tab navigation works across tmux and normal buffers."
  (let* ((pane-id (tmux-cc-e2e--visit-first-pane))
         (pane-window (selected-window))
         (buffer-name (generate-new-buffer-name "*tmux-cc-mixed*"))
         (buffer (get-buffer-create buffer-name)))
    (split-window-right)
    (other-window 1)
    (switch-to-buffer buffer)
    (tmux-cc-e2e--wait 5)
    (select-window pane-window)
    (tmux-cc-smart-next-window)
    (tmux-cc-e2e--wait 5)
    (tmux-cc-e2e--assert (equal (window-buffer (selected-window)) buffer)
                          "Smart next window did not leave the tmux pane for a normal buffer")
    (tmux-cc-smart-previous-window)
    (tmux-cc-e2e--wait 5)
    (tmux-cc-e2e--assert (equal (tmux-cc-e2e--visible-pane-id) pane-id)
                          "Smart previous window did not return to the tmux pane")
    (kill-buffer buffer))
  "ok-mixed-window-navigation")

(defun tmux-cc-e2e-test-manager-new-window ()
  "Verify manager-driven window creation."
  (tmux-cc-e2e-manager-open)
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _args) tmux-cc-e2e-window-name)))
    (with-current-buffer tmux-cc-manager-buffer-name
      (tmux-cc-manager-new-window)))
  (tmux-cc-e2e--wait 30)
  (tmux-cc-e2e-manager-goto-label 'window tmux-cc-e2e-window-name)
  "ok-manager-new-window")

(defun tmux-cc-e2e-test-switch-window ()
  "Verify interactive window switching."
  (tmux-cc-switch-window (format "%s:%s" tmux-cc-e2e-session tmux-cc-e2e-window-name))
  (tmux-cc-e2e--wait 30)
  (let ((targets (tmux-cc-e2e-manager-targets)))
    (tmux-cc-e2e--assert
     (cl-find-if
      (lambda (item)
        (and (eq (plist-get item :type) 'window)
             (string-prefix-p "*" (plist-get item :line))
             (string-match-p (regexp-quote tmux-cc-e2e-window-name)
                             (plist-get item :label))))
      targets)
     "Interactive switch-window did not activate %s" tmux-cc-e2e-window-name))
  "ok-switch-window")

(defun tmux-cc-e2e-test-manager-new-session ()
  "Verify manager-driven session creation."
  (tmux-cc-e2e-manager-open)
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _args) tmux-cc-e2e-session-2)))
    (with-current-buffer tmux-cc-manager-buffer-name
      (tmux-cc-manager-new-session)))
  (tmux-cc-e2e--wait 30)
  (tmux-cc-e2e-manager-goto-id 'session tmux-cc-e2e-session-2)
  "ok-manager-new-session")

(defun tmux-cc-e2e-test-switch-session ()
  "Verify interactive session switching."
  (tmux-cc-switch-session tmux-cc-e2e-session-2)
  (tmux-cc-e2e--wait 30)
  (let ((targets (tmux-cc-e2e-manager-targets)))
    (tmux-cc-e2e--assert
     (cl-find-if
      (lambda (item)
        (and (eq (plist-get item :type) 'session)
             (string= (plist-get item :id) tmux-cc-e2e-session-2)
             (string-prefix-p "*" (plist-get item :line))))
      targets)
     "Interactive switch-session did not activate %s" tmux-cc-e2e-session-2))
  "ok-switch-session")

(defun tmux-cc-e2e-test-manager-visit-window ()
  "Verify manager visit on a window line."
  (let ((buffer-name
         (tmux-cc-e2e-manager-visit-id 'window "@0")))
    (tmux-cc-e2e--assert
     (string-prefix-p tmux-cc-pane-buffer-prefix buffer-name)
     "Manager window visit did not land in a pane buffer"))
  "ok-visit-window")

(defun tmux-cc-e2e-test-manager-visit-pane ()
  "Verify manager visit on a pane line."
  (let* ((targets (tmux-cc-e2e-manager-targets))
         (pane-id (plist-get (cl-find-if (lambda (item) (eq (plist-get item :type) 'pane))
                                         targets)
                             :id))
         (buffer-name (tmux-cc-e2e-manager-visit-id 'pane pane-id)))
    (tmux-cc-e2e--assert
     (string-prefix-p tmux-cc-pane-buffer-prefix buffer-name)
     "Manager pane visit did not land in a pane buffer"))
  "ok-visit-pane")

(defun tmux-cc-e2e-test-manager-command ()
  "Verify arbitrary tmux commands from the manager."
  (tmux-cc-e2e-manager-open)
  (with-current-buffer tmux-cc-manager-buffer-name
    (tmux-cc-manager-command "display-message manager-command"))
  (tmux-cc-e2e--wait 10)
  "ok-manager-command")

(defun tmux-cc-e2e-test-manager-delete-pane ()
  "Verify manager deletion of a pane."
  (let* ((targets (tmux-cc-e2e-manager-targets))
         (pane (cl-find-if
                (lambda (item)
                  (and (eq (plist-get item :type) 'pane)
                       (string-match-p (regexp-quote tmux-cc-e2e-session)
                                       (plist-get item :line))))
                targets))
         (pane-id (plist-get pane :id)))
    (tmux-cc-e2e--assert pane-id "No pane target available for pane deletion")
    (tmux-cc-e2e-manager-delete-id 'pane pane-id)
    (tmux-cc-e2e--assert
     (not (cl-find-if (lambda (item)
                        (and (eq (plist-get item :type) 'pane)
                             (equal (plist-get item :id) pane-id)))
                      (tmux-cc-e2e-manager-targets)))
     "Manager pane delete did not remove %s" pane-id))
  "ok-delete-pane")

(defun tmux-cc-e2e-test-manager-delete-window ()
  "Verify manager deletion of a window."
  (let* ((targets (tmux-cc-e2e-manager-targets))
         (window (cl-find-if
                  (lambda (item)
                    (and (eq (plist-get item :type) 'window)
                         (string-match-p (regexp-quote tmux-cc-e2e-window-name)
                                         (plist-get item :label))))
                  targets))
         (window-id (plist-get window :id)))
    (tmux-cc-e2e--assert window-id "No window target available for window deletion")
    (tmux-cc-e2e-manager-delete-id 'window window-id)
    (tmux-cc-e2e--assert
     (not (cl-find-if
           (lambda (item)
             (and (eq (plist-get item :type) 'window)
                  (equal (plist-get item :id) window-id)))
           (tmux-cc-e2e-manager-targets)))
     "Manager window delete did not remove %s" window-id))
  "ok-delete-window")

(defun tmux-cc-e2e-test-manager-delete-session ()
  "Verify manager deletion of a detached session."
  (tmux-cc-e2e-manager-delete-id 'session tmux-cc-e2e-session-2)
  (tmux-cc-e2e--assert
   (not (cl-find-if
         (lambda (item)
           (and (eq (plist-get item :type) 'session)
                (equal (plist-get item :id) tmux-cc-e2e-session-2)))
         (tmux-cc-e2e-manager-targets)))
   "Manager session delete did not remove %s" tmux-cc-e2e-session-2)
  "ok-delete-session")

(defun tmux-cc-e2e-test-detach ()
  "Verify client detach."
  (tmux-cc-e2e-manager-open)
  (with-current-buffer tmux-cc-manager-buffer-name
    (tmux-cc-manager-detach))
  (tmux-cc-e2e--wait 20)
  (tmux-cc-e2e--assert (not (process-live-p tmux-cc-process))
                        "Detach did not stop the tmux control process")
  "ok-detach")

(defun tmux-cc-e2e--run-isolated (&rest steps)
  "Run live tmux e2e STEPS inside a fresh disposable session."
  (let ((window-config (current-window-configuration)))
    (unwind-protect
        (let (result)
          (dolist (step steps)
            (setq result (funcall step)))
          result)
      (ignore-errors
        (set-window-configuration window-config))
      (ignore-errors
        (tmux-cc-e2e-stop)))))

(defun tmux-cc-e2e-case-start ()
  "Run the startup e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start))

(defun tmux-cc-e2e-case-command ()
  "Run the arbitrary command e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-command))

(defun tmux-cc-e2e-case-preview ()
  "Run the manager preview e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-preview))

(defun tmux-cc-e2e-case-help ()
  "Run the manager help e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-help))

(defun tmux-cc-e2e-case-splits-focus ()
  "Run the split and focus e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-splits-and-focus))

(defun tmux-cc-e2e-case-vertical-tab-focus ()
  "Run the vertical tab-focus e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-vertical-tab-focus))

(defun tmux-cc-e2e-case-kill-pane ()
  "Run the direct kill-pane e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-kill-pane))

(defun tmux-cc-e2e-case-emacs-window-arrangement ()
  "Run the Emacs-only window arrangement e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-emacs-window-arrangement))

(defun tmux-cc-e2e-case-mixed-window-navigation ()
  "Run the mixed tmux/non-tmux window navigation e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-mixed-window-navigation))

(defun tmux-cc-e2e-case-manager-new-window ()
  "Run the manager new-window e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-manager-new-window))

(defun tmux-cc-e2e-case-switch-window ()
  "Run the switch-window e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-manager-new-window
   #'tmux-cc-e2e-test-switch-window))

(defun tmux-cc-e2e-case-manager-new-session ()
  "Run the manager new-session e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-manager-new-session))

(defun tmux-cc-e2e-case-switch-session ()
  "Run the switch-session e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-manager-new-session
   #'tmux-cc-e2e-test-switch-session))

(defun tmux-cc-e2e-case-manager-visit-window ()
  "Run the manager visit-window e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-manager-new-window
   #'tmux-cc-e2e-test-manager-visit-window))

(defun tmux-cc-e2e-case-manager-visit-pane ()
  "Run the manager visit-pane e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-splits-and-focus
   #'tmux-cc-e2e-test-manager-visit-pane))

(defun tmux-cc-e2e-case-manager-command ()
  "Run the manager command e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-manager-command))

(defun tmux-cc-e2e-case-manager-delete-pane ()
  "Run the manager delete-pane e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-splits-and-focus
   #'tmux-cc-e2e-test-manager-delete-pane))

(defun tmux-cc-e2e-case-manager-delete-window ()
  "Run the manager delete-window e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-manager-new-window
   #'tmux-cc-e2e-test-manager-delete-window))

(defun tmux-cc-e2e-case-manager-delete-session ()
  "Run the manager delete-session e2e case."
  (tmux-cc-e2e--run-isolated
   #'tmux-cc-e2e-test-start
   #'tmux-cc-e2e-test-manager-new-session
   #'tmux-cc-e2e-test-manager-delete-session))

(defun tmux-cc-e2e-case-detach ()
  "Run the detach e2e case."
  (tmux-cc-e2e--run-isolated #'tmux-cc-e2e-test-start #'tmux-cc-e2e-test-detach))

(defun tmux-cc-e2e-run ()
  "Run the full live tmux-cc end-to-end suite against the current Emacs server."
  (let ((steps
         '(("start" . tmux-cc-e2e-case-start)
           ("command" . tmux-cc-e2e-case-command)
           ("preview" . tmux-cc-e2e-case-preview)
           ("help" . tmux-cc-e2e-case-help)
           ("emacs-window-arrangement" . tmux-cc-e2e-case-emacs-window-arrangement)
           ("mixed-window-navigation" . tmux-cc-e2e-case-mixed-window-navigation)
           ("splits-focus" . tmux-cc-e2e-case-splits-focus)
           ("vertical-tab-focus" . tmux-cc-e2e-case-vertical-tab-focus)
           ("kill-pane" . tmux-cc-e2e-case-kill-pane)
           ("manager-new-window" . tmux-cc-e2e-case-manager-new-window)
           ("switch-window" . tmux-cc-e2e-case-switch-window)
           ("manager-new-session" . tmux-cc-e2e-case-manager-new-session)
           ("switch-session" . tmux-cc-e2e-case-switch-session)
           ("manager-visit-window" . tmux-cc-e2e-case-manager-visit-window)
           ("manager-visit-pane" . tmux-cc-e2e-case-manager-visit-pane)
           ("manager-command" . tmux-cc-e2e-case-manager-command)
           ("manager-delete-pane" . tmux-cc-e2e-case-manager-delete-pane)
           ("manager-delete-window" . tmux-cc-e2e-case-manager-delete-window)
           ("manager-delete-session" . tmux-cc-e2e-case-manager-delete-session)
           ("detach" . tmux-cc-e2e-case-detach))))
    (dolist (step steps)
      (condition-case err
          (funcall (cdr step))
        (error
         (error "e2e step %s failed: %s" (car step) (error-message-string err)))))
    "ok"))

(provide 'tmux-cc-e2e)
;;; tmux-cc-e2e.el ends here
