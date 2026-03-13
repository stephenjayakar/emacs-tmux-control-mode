;;; tmux-cc.el --- tmux -CC integration for Emacs -*- lexical-binding: t; -*-

;; Author: stephenjayakar
;; Keywords: terminals, tmux

(require 'term)

(defgroup tmux-cc nil
  "tmux control mode integration."
  :group 'term)

(defcustom tmux-cc-passthrough-keys
  '("C-x" "M-x" "C-<tab>" "C-S-<tab>" "C-M-S-<tab>" "s-]" "s-{" "s-t" "s-w" "C-\\")
  "List of key sequences that should bypass term-char-mode interception.
This allows global Emacs window management and command keys to function
normally while inside a tmux pane."
  :type '(repeat string)
  :group 'tmux-cc)

(defvar tmux-cc-process nil
  "The active tmux -CC process.")

(defvar tmux-cc--buffer ""
  "Buffer for incomplete lines from the tmux process.")

(defvar tmux-cc-panes (make-hash-table :test 'equal)
  "Hash table mapping pane ID (e.g. \"%1\") to its Emacs buffer.")

(defvar tmux-cc--cmd-queue nil
  "FIFO queue of callbacks for tmux commands.")

(defvar tmux-cc--current-cmd-lines nil
  "Accumulated output lines for the current command.")

(defvar tmux-cc--in-cmd nil
  "Non-nil if currently receiving command output.")

;;; --- Layout Parser ---

(defun tmux-cc--parse-node (str pos)
  "Parse a layout node from STR starting at POS.
Returns ((TYPE WIDTH HEIGHT X Y PANE-ID CHILDREN) . NEXT-POS)."
  (let ((len (length str)))
    (if (string-match
         "\\([0-9]+\\)x\\([0-9]+\\),\\([0-9]+\\),\\([0-9]+\\)"
         str pos)
        (let* ((width (string-to-number (match-string 1 str)))
               (height (string-to-number (match-string 2 str)))
               (x (string-to-number (match-string 3 str)))
               (y (string-to-number (match-string 4 str)))
               (match-end-pos (match-end 0))
               (pane-id nil)
               (children nil)
               (type 'pane)
               (curr-pos match-end-pos))
          ;; Now we check what's next
          (if (< curr-pos len)
              (let ((c (aref str curr-pos)))
                (cond
                 ((= c ?,) ;; pane ID
                  (setq curr-pos (1+ curr-pos))
                  (if (string-match "\\([0-9]+\\)" str curr-pos)
                      (progn
                        (setq pane-id (match-string 1 str))
                        (setq curr-pos (match-end 0)))
                    (error "Expected pane ID at %d" curr-pos)))

                 ((= c ?\[) ;; vertical split
                  (setq type 'vertical)
                  (setq curr-pos (1+ curr-pos))
                  (let ((parsed-children
                         (tmux-cc--parse-children str curr-pos ?\])))
                    (setq children (car parsed-children))
                    (setq curr-pos (cdr parsed-children))))

                 ((= c ?{) ;; horizontal split
                  (setq type 'horizontal)
                  (setq curr-pos (1+ curr-pos))
                  (let ((parsed-children
                         (tmux-cc--parse-children str curr-pos ?})))
                    (setq children (car parsed-children))
                    (setq curr-pos (cdr parsed-children))))

                 (t nil)))) ;; could be end of string or sibling comma
          (cons (list type width height x y pane-id children) curr-pos)))))

(defun tmux-cc--parse-children (str pos end-char)
  "Parse children separated by commas until END-CHAR."
  (let ((children nil)
        (curr-pos pos)
        (len (length str)))
    (while (and (< curr-pos len) (/= (aref str curr-pos) end-char))
      (let ((parsed-node (tmux-cc--parse-node str curr-pos)))
        (push (car parsed-node) children)
        (setq curr-pos (cdr parsed-node)))
      ;; If we see a comma, skip it for the next sibling
      (when (and (< curr-pos len) (= (aref str curr-pos) ?,))
        (setq curr-pos (1+ curr-pos))))
    (if (and (< curr-pos len) (= (aref str curr-pos) end-char))
        (setq curr-pos (1+ curr-pos)) ;; consume end-char
      (error "Expected end character %c at %d" end-char curr-pos))
    (cons (nreverse children) curr-pos)))

(defun tmux-cc-parse-layout-string (layout-str)
  "Parse a full tmux layout string."
  (let* ((comma-pos (string-search "," layout-str))
         (rest (if comma-pos (substring layout-str (1+ comma-pos)) layout-str)))
    (car (tmux-cc--parse-node rest 0))))

(defun tmux-cc-apply-layout (node root-window)
  "Recursively apply layout NODE to ROOT-WINDOW."
  (let ((type (nth 0 node))
        (pane-id (nth 5 node))
        (children (nth 6 node)))
    (cond
     ((eq type 'pane)
      ;; Leaf node: associate this Emacs window with the tmux pane-id.
      (let* ((pane-id-str (format "%%%s" pane-id))
             (buf (gethash pane-id-str tmux-cc-panes)))
        (unless (buffer-live-p buf)
          (setq buf (tmux-cc-create-pane pane-id-str)))
        (set-window-buffer root-window buf)))

     ((eq type 'horizontal)
      ;; Left-Right split (...)
      (let ((curr-win root-window)
            (remaining children))
        (while remaining
          (let* ((child (car remaining))
                 (width (nth 1 child))
                 (next-win (if (cdr remaining)
                               (split-window curr-win width t)
                             nil)))
            (tmux-cc-apply-layout child curr-win)
            (setq curr-win next-win)
            (setq remaining (cdr remaining))))))

     ((eq type 'vertical)
      ;; Top-Bottom split (...)
      (let ((curr-win root-window)
            (remaining children))
        (while remaining
          (let* ((child (car remaining))
                 (height (nth 2 child))
                 (next-win (if (cdr remaining)
                               (split-window curr-win height nil)
                             nil)))
            (tmux-cc-apply-layout child curr-win)
            (setq curr-win next-win)
            (setq remaining (cdr remaining)))))))))

;;; --- Process & Notification Handling ---

(defun tmux-cc-start (command)
  "Start a tmux -CC process with the given shell COMMAND.
COMMAND should be like \"tmux -CC attach\" or \"ssh -t host tmux -CC attach\".
We use a pty so that ssh passes the local terminal modes (-echo)
to the remote side, preventing early echoing of commands."
  (interactive
   (list (read-shell-command "tmux command: ")))
  (when (process-live-p tmux-cc-process)
    (if (y-or-n-p "A tmux-cc process is already running. Kill it? ")
        (delete-process tmux-cc-process)
      (user-error "tmux-cc process already running")))

  (setq tmux-cc--buffer "")
  (clrhash tmux-cc-panes)

  (setq tmux-cc-process
        (make-process
         :name "tmux-cc"
         :buffer (generate-new-buffer "*tmux-cc*")
         :command (split-string-and-unquote command)
         :connection-type 'pty
         :filter #'tmux-cc--filter
         :sentinel #'tmux-cc--sentinel))

  (message "Started tmux-cc process."))

(defun tmux-cc--filter (process string)
  "Filter for the tmux-cc PROCESS receiving STRING."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (save-excursion
        (goto-char (point-max))
        (insert string))))
  (setq tmux-cc--buffer (concat tmux-cc--buffer string))
  (let ((lines (split-string tmux-cc--buffer "\n" t)))
    ;; If the buffer doesn't end with a newline, the last element is incomplete.
    (if (not (string-suffix-p "\n" tmux-cc--buffer))
        (progn
          (setq tmux-cc--buffer (car (last lines)))
          (setq lines (butlast lines)))
      (setq tmux-cc--buffer ""))
    (dolist (line lines)
      (let ((clean-line (string-trim-right line "\r")))
        (tmux-cc--handle-line clean-line)))))

(defun tmux-cc--sentinel (_process event)
  "Sentinel for the tmux-cc PROCESS receiving EVENT."
  (message "tmux-cc process %s" (string-trim event)))

(defun tmux-cc--handle-line (line)
  "Handle a single LINE from tmux control mode."
  (cond
   ((string-prefix-p "%begin " line)
    (setq tmux-cc--in-cmd t)
    (setq tmux-cc--current-cmd-lines nil))

   ((string-prefix-p "%end " line)
    (setq tmux-cc--in-cmd nil)
    (let ((cb (pop tmux-cc--cmd-queue)))
      (when cb
        (funcall cb (nreverse tmux-cc--current-cmd-lines)))))

   ((string-prefix-p "%error " line)
    (setq tmux-cc--in-cmd nil)
    (let ((cb (pop tmux-cc--cmd-queue)))
      (when cb
        ;; Pass nil or the error lines to the callback if desired
        (funcall cb (nreverse tmux-cc--current-cmd-lines))))
    (message "tmux error: %s" line))

   (tmux-cc--in-cmd
    (push line tmux-cc--current-cmd-lines))

   ((string-prefix-p "%output " line)
    (let ((space1 (string-match " " line)))
      (when space1
        (let ((space2 (string-match " " line (1+ space1))))
          (when space2
            (let ((pane-id (substring line (1+ space1) space2))
                  (output-str (substring line (1+ space2))))
              (tmux-cc--handle-output pane-id output-str)))))))

   ((string-prefix-p "%layout-change " line)
    (let* ((parts (split-string line " "))
           (window-id (nth 1 parts))
           (layout (nth 2 parts)))
      (tmux-cc--handle-layout-change window-id layout)))

   ((string-prefix-p "%window-add " line)
    (message "tmux window added: %s" line))

   ((string-prefix-p "%window-close " line)
    (message "tmux window closed: %s" line))

   ((string-prefix-p "window-close " line)
    (message "tmux window closed: %s" line))

   ((string-prefix-p "%pane-mode-changed " line)
    ;; Do nothing for now
    )

   ((string-prefix-p "%session-changed " line)
    (message "tmux session changed: %s" line))

   ((string-prefix-p "%sessions-changed" line)
    ;; Do nothing
    )

   (t
    ;; Unhandled or background output
    (message "tmux: %s" line))))

(defun tmux-cc--decode-octal (str)
  "Decode octal escapes like \\015\\012 in STR."
  ;; tmux control mode replaces chars < 32 and \ with octal, e.g., \134.
  ;; We can use replace-regexp-in-string to evaluate the octal.
  (replace-regexp-in-string
   "\\\\\\([0-7][0-7][0-7]\\)"
   (lambda (match)
     (let ((num (string-to-number (match-string 1 match) 8)))
       (string num)))
   str
   t t))

(defun tmux-cc--strip-osc (str)
  "Strip OSC (Operating System Command) escape sequences from STR.
Emacs term.el does not handle sequences like \\e]2;title\\a properly
and will print ']2;title' directly into the buffer."
  (replace-regexp-in-string
   "\\e\\][0-9]+;\\([^\\a\\e]\\|\\e[^\\\\]\\)*\\(\\a\\|\\e\\\\\\)"
   ""
   str))

(defun tmux-cc--handle-output (pane-id str)
  "Handle output STR for PANE-ID."
  (let* ((decoded (tmux-cc--decode-octal str))
         (clean (tmux-cc--strip-osc decoded))
         (buf (gethash pane-id tmux-cc-panes)))
    (unless (buffer-live-p buf)
      (setq buf (tmux-cc-create-pane pane-id)))
    (let ((proc (get-buffer-process buf)))
      (when proc
        (term-emulate-terminal proc clean)))))

(defun tmux-cc--handle-layout-change (_window-id layout-str)
  "Handle layout change for WINDOW-ID with new LAYOUT-STR."
  (message "Handling layout change: %s" layout-str)
  (let ((node (tmux-cc-parse-layout-string layout-str)))
    ;; Apply layout to the selected window. First close others.
    (delete-other-windows)
    (tmux-cc-apply-layout node (selected-window))))

(defun tmux-cc-create-pane (pane-id)
  "Create a term buffer for tmux PANE-ID."
  (let* ((buf-name (format "*tmux-pane %s*" pane-id))
         (buf (generate-new-buffer buf-name)))
    (puthash pane-id buf tmux-cc-panes)
    (with-current-buffer buf
      (let ((proc (make-process
                   :name (format "tmux-pane-%s" pane-id)
                   :buffer buf
                   :command '("sleep" "1000000")
                   :connection-type 'pty)))
        (set-process-filter proc 'term-emulate-terminal)
        (set-process-sentinel proc 'term-sentinel)
        (process-put proc 'tmux-cc-pane-id pane-id)
        (term-mode)
        ;; Make a buffer-local copy of term-raw-map to unbind passthrough keys
        (setq-local term-raw-map (copy-keymap term-raw-map))
        (dolist (key tmux-cc-passthrough-keys)
          (define-key term-raw-map (kbd key) nil))
        (term-char-mode)))
    buf))

(defun tmux-cc--send-keys (pane-id string)
  "Send keystrokes to PANE-ID. STRING is a raw string of chars."
  (when (process-live-p tmux-cc-process)
    ;; Convert string to space-separated hex bytes
    (let ((hex-args (mapconcat (lambda (c) (format "%02X" c)) string " ")))
      (process-send-string
       tmux-cc-process
       (format "send-keys -t %s -H %s\n" pane-id hex-args)))))

(defun tmux-cc--intercept-process-send-string (orig-fun proc string &rest args)
  "Intercept input to tmux-cc dummy processes and route to tmux-cc."
  (if (and (processp proc)
           (process-get proc 'tmux-cc-pane-id)
           (bound-and-true-p tmux-cc-process)
           (process-live-p tmux-cc-process))
      (let* ((pane-id (process-get proc 'tmux-cc-pane-id)))
        (tmux-cc--send-keys pane-id string))
    (apply orig-fun proc string args)))

(advice-add 'process-send-string :around #'tmux-cc--intercept-process-send-string)

;;; --- Interactive Window Management Interception ---

(defun tmux-cc--intercept-split-window-right (orig-fun &rest args)
  (let* ((proc (get-buffer-process (current-buffer)))
         (pane-id (and proc (processp proc) (process-get proc 'tmux-cc-pane-id))))
    (if (and (called-interactively-p 'any)
             pane-id
             (eq major-mode 'term-mode)
             (bound-and-true-p tmux-cc-process)
             (process-live-p tmux-cc-process))
        (process-send-string tmux-cc-process (format "split-window -h -t %s\n" pane-id))
      (apply orig-fun args))))

(defun tmux-cc--intercept-split-window-below (orig-fun &rest args)
  (let* ((proc (get-buffer-process (current-buffer)))
         (pane-id (and proc (processp proc) (process-get proc 'tmux-cc-pane-id))))
    (if (and (called-interactively-p 'any)
             pane-id
             (eq major-mode 'term-mode)
             (bound-and-true-p tmux-cc-process)
             (process-live-p tmux-cc-process))
        (process-send-string tmux-cc-process (format "split-window -v -t %s\n" pane-id))
      (apply orig-fun args))))

(defun tmux-cc--intercept-delete-window (orig-fun &optional window)
  (let* ((win (or window (selected-window)))
         (buf (window-buffer win))
         (proc (get-buffer-process buf))
         (pane-id (and proc (processp proc) (process-get proc 'tmux-cc-pane-id))))
    (if (and (called-interactively-p 'any)
             pane-id
             (buffer-live-p buf)
             (with-current-buffer buf (eq major-mode 'term-mode))
             (bound-and-true-p tmux-cc-process)
             (process-live-p tmux-cc-process))
        (process-send-string tmux-cc-process (format "kill-pane -t %s\n" pane-id))
      (funcall orig-fun window))))

(defun tmux-cc--intercept-delete-other-windows (orig-fun &optional window)
  (let* ((win (or window (selected-window)))
         (buf (window-buffer win))
         (proc (get-buffer-process buf))
         (pane-id (and proc (processp proc) (process-get proc 'tmux-cc-pane-id))))
    (if (and (called-interactively-p 'any)
             pane-id
             (buffer-live-p buf)
             (with-current-buffer buf (eq major-mode 'term-mode))
             (bound-and-true-p tmux-cc-process)
             (process-live-p tmux-cc-process))
        (process-send-string tmux-cc-process (format "kill-pane -a -t %s\n" pane-id))
      (funcall orig-fun window))))

(advice-add 'split-window-right :around #'tmux-cc--intercept-split-window-right)
(advice-add 'split-window-below :around #'tmux-cc--intercept-split-window-below)
(advice-add 'delete-window :around #'tmux-cc--intercept-delete-window)
(advice-add 'delete-other-windows :around #'tmux-cc--intercept-delete-other-windows)

(defun tmux-cc-send-command (cmd &optional callback)
  "Send CMD to tmux. If CALLBACK is provided, it is called with output lines."
  (when (process-live-p tmux-cc-process)
    (when callback
      (setq tmux-cc--cmd-queue (append tmux-cc--cmd-queue (list callback))))
    (process-send-string tmux-cc-process (concat cmd "\n"))))

(defun tmux-cc-command (cmd)
  "Send an arbitrary tmux COMMAND to the active tmux-cc session."
  (interactive "sTmux command: ")
  (tmux-cc-send-command cmd (lambda (out) (message "tmux: %s" (string-join out "\n")))))

(defun tmux-cc-switch-session ()
  "Interactively select and switch to another tmux session."
  (interactive)
  (tmux-cc-send-command
   "list-sessions -F '#{session_name}'"
   (lambda (lines)
     (if (not lines)
         (message "No sessions found or command failed.")
       (let ((session (completing-read "Switch to session: " lines nil t)))
         (when session
           (tmux-cc-send-command (format "switch-client -t '%s'" session))))))))

(defun tmux-cc-switch-window ()
  "Interactively select and switch to another tmux window."
  (interactive)
  (tmux-cc-send-command
   "list-windows -a -F '#{session_name}:#{window_name}'"
   (lambda (lines)
     (if (not lines)
         (message "No windows found or command failed.")
       (let ((window-str (completing-read "Switch to window: " lines nil t)))
         (when window-str
           ;; Select the actual window name/id target.
           ;; Target string can just be the selected text since it's 'session:window'.
           (tmux-cc-send-command (format "select-window -t '%s'" window-str))))))))

(provide 'tmux-cc)
;; tmux-cc.el ends here
