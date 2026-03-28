;;; tmux-cc.el --- tmux control mode integration for Emacs -*- lexical-binding: t; -*-

;; Author: Stephen Jayakar <stephenjayakar@gmail.com>
;; Maintainer: Stephen Jayakar <stephenjayakar@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: terminals, tmux, tools
;; URL: https://github.com/stephenjayakar/emacs-tmux-control-mode

;;; Commentary:

;; tmux-cc.el integrates tmux control mode (`tmux -CC`) with Emacs. It
;; creates a term buffer per tmux pane, mirrors tmux layout changes into Emacs
;; windows, and exposes commands for splitting panes, switching windows and
;; sessions, and sending arbitrary tmux commands.

;;; Code:

(require 'subr-x)
(require 'term)
(require 'windmove)

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

(defcustom tmux-cc-strip-problematic-escape-sequences t
  "When non-nil, strip terminal mode sequences that `term.el` displays visibly."
  :type 'boolean
  :group 'tmux-cc)

(defcustom tmux-cc-focus-next-key "C-<tab>"
  "Key used in tmux pane buffers to focus the pane to the right."
  :type 'string
  :group 'tmux-cc)

(defcustom tmux-cc-focus-prev-key "C-S-<tab>"
  "Key used in tmux pane buffers to focus the pane to the left."
  :type 'string
  :group 'tmux-cc)

(defcustom tmux-cc-focus-other-key "C-x o"
  "Key used in tmux pane buffers to focus another tmux pane."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-command-key "C-c C-c"
  "Key used in tmux pane buffers for `tmux-cc-command'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-switch-window-key "C-c C-w"
  "Key used in tmux pane buffers for `tmux-cc-switch-window'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-switch-session-key "C-c C-s"
  "Key used in tmux pane buffers for `tmux-cc-switch-session'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-detach-key "C-c C-d"
  "Key used in tmux pane buffers for detaching the tmux client."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-manager-buffer-name "*tmux-control*"
  "Name of the tmux management buffer."
  :type 'string
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

(defvar tmux-cc-pane-mode-map (make-sparse-keymap)
  "Keymap active in tmux pane buffers.")

(defvar tmux-cc-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'tmux-cc-manager-refresh)
    (define-key map (kbd "RET") #'tmux-cc-manager-visit)
    map)
  "Keymap for `tmux-cc-manager-mode'.")

(define-minor-mode tmux-cc-pane-mode
  "Minor mode for tmux pane buffers."
  :lighter " TmuxCC"
  :keymap tmux-cc-pane-mode-map)

(define-derived-mode tmux-cc-manager-mode special-mode "Tmux-Control"
  "Major mode for inspecting tmux sessions, windows, and panes.")

(defun tmux-cc--bind-pane-key (key command)
  "Bind KEY to COMMAND in `tmux-cc-pane-mode-map'.
If KEY is nil, remove any existing binding for COMMAND's slot."
  (when key
    (define-key tmux-cc-pane-mode-map (kbd key) command)))

(defun tmux-cc-setup-keybindings ()
  "Apply customizable tmux pane keybindings."
  (setcdr tmux-cc-pane-mode-map nil)
  (tmux-cc--bind-pane-key tmux-cc-focus-next-key #'tmux-cc-focus-right)
  (tmux-cc--bind-pane-key tmux-cc-focus-prev-key #'tmux-cc-focus-left)
  (tmux-cc--bind-pane-key tmux-cc-focus-other-key #'tmux-cc-focus-next-pane)
  (tmux-cc--bind-pane-key tmux-cc-command-key #'tmux-cc-command)
  (tmux-cc--bind-pane-key tmux-cc-switch-window-key #'tmux-cc-switch-window)
  (tmux-cc--bind-pane-key tmux-cc-switch-session-key #'tmux-cc-switch-session)
  (tmux-cc--bind-pane-key tmux-cc-detach-key #'tmux-cc-detach))

(tmux-cc-setup-keybindings)

(defun tmux-cc--tmux-target (target)
  "Quote tmux TARGET for command use."
  (format "'%s'" target))

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
  (unless (hash-table-p tmux-cc-panes)
    (setq tmux-cc-panes (make-hash-table :test 'equal)))
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
   (rx "\e]" (* (not (any "\a" "\e"))) (or "\a" "\e\\"))
   ""
   str t t))

(defun tmux-cc--strip-problematic-escapes (str)
  "Strip terminal escape sequences from STR that `term.el` misrenders."
  (let ((clean str))
    (setq clean (replace-regexp-in-string "\e[=>]" "" clean t t))
    (setq clean (replace-regexp-in-string "\ek[^\e]*\e\\\\" "" clean t t))
    clean))

(defun tmux-cc--handle-output (pane-id str)
  "Handle output STR for PANE-ID."
  (let* ((decoded (tmux-cc--decode-octal str))
         (clean (tmux-cc--strip-osc decoded))
         (clean (if tmux-cc-strip-problematic-escape-sequences
                    (tmux-cc--strip-problematic-escapes clean)
                  clean))
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
        (term-char-mode)
        (tmux-cc-pane-mode 1)))
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

(defun tmux-cc--current-pane-id ()
  "Return the pane id associated with the current buffer, or nil."
  (let ((proc (get-buffer-process (current-buffer))))
    (and (processp proc)
         (process-get proc 'tmux-cc-pane-id))))

(defun tmux-cc--select-pane (selector)
  "Select tmux pane using SELECTOR from the current pane buffer."
  (let ((pane-id (tmux-cc--current-pane-id)))
    (unless pane-id
      (user-error "Current buffer is not a tmux pane"))
    (tmux-cc-send-command (format "select-pane %s -t %s" selector pane-id))))

(defun tmux-cc--focus-window (move-fn)
  "Move Emacs selection with MOVE-FN when possible."
  (when (fboundp move-fn)
    (ignore-errors
      (funcall move-fn))))

(defun tmux-cc-focus-right ()
  "Focus the tmux pane to the right."
  (interactive)
  (tmux-cc--select-pane "-R")
  (tmux-cc--focus-window #'windmove-right))

(defun tmux-cc-focus-left ()
  "Focus the tmux pane to the left."
  (interactive)
  (tmux-cc--select-pane "-L")
  (tmux-cc--focus-window #'windmove-left))

(defun tmux-cc-focus-up ()
  "Focus the tmux pane above."
  (interactive)
  (tmux-cc--select-pane "-U")
  (tmux-cc--focus-window #'windmove-up))

(defun tmux-cc-focus-down ()
  "Focus the tmux pane below."
  (interactive)
  (tmux-cc--select-pane "-D")
  (tmux-cc--focus-window #'windmove-down))

(defun tmux-cc-focus-next-pane ()
  "Focus another tmux pane.
Currently this uses rightward pane motion as the default ergonomic behavior."
  (interactive)
  (tmux-cc-focus-right))

(defun tmux-cc-detach ()
  "Detach the active tmux client."
  (interactive)
  (tmux-cc-send-command "detach-client"))

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

(defun tmux-cc-manager ()
  "Open the tmux management buffer."
  (interactive)
  (let ((buffer (get-buffer-create tmux-cc-manager-buffer-name)))
    (with-current-buffer buffer
      (tmux-cc-manager-mode)
      (setq-local revert-buffer-function #'tmux-cc-manager-refresh))
    (pop-to-buffer buffer)
    (tmux-cc-manager-refresh)))

(defun tmux-cc-manager-refresh (&rest _)
  "Refresh the tmux management buffer."
  (interactive)
  (unless (process-live-p tmux-cc-process)
    (user-error "tmux-cc process is not running"))
  (tmux-cc-send-command
   "list-windows -a -F '#{session_name}\t#{window_name}\t#{window_id}\t#{window_active}\t#{window_layout}\t#{pane_id}'"
   (lambda (windows)
     (tmux-cc-send-command
      "list-panes -a -F '#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_width}x#{pane_height}'"
      (lambda (panes)
        (tmux-cc--render-manager-buffer windows panes))))))

(defun tmux-cc--render-manager-buffer (windows panes)
  "Render tmux manager buffer using WINDOWS and PANES command output."
  (let ((buffer (get-buffer-create tmux-cc-manager-buffer-name)))
    (with-current-buffer buffer
      (tmux-cc-manager-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Tmux Control\n" 'face 'bold))
        (insert (propertize "g refresh, RET visit target\n\n" 'face 'shadow))
        (insert (propertize "Windows\n" 'face 'underline))
        (dolist (line windows)
          (pcase-let ((`(,session ,window-name ,window-id ,active ,layout ,_pane-id)
                       (split-string line "\t")))
            (let ((start (point)))
              (insert (format "%s %-16s %-16s %-4s %s\n"
                              (if (string= active "1") "*" " ")
                              session
                              window-name
                              window-id
                              layout))
              (add-text-properties
               start (point)
               (list 'tmux-target-type 'window
                     'tmux-target-id window-id
                     'mouse-face 'highlight
                     'help-echo "RET: select tmux window")))))
        (insert "\n")
        (insert (propertize "Panes\n" 'face 'underline))
        (dolist (line panes)
          (pcase-let ((`(,session ,window-id ,pane-id ,active ,command ,size)
                       (split-string line "\t")))
            (let ((start (point)))
              (insert (format "%s %-16s %-6s %-6s %-16s %s\n"
                              (if (string= active "1") "*" " ")
                              session
                              window-id
                              pane-id
                              command
                              size))
              (add-text-properties
               start (point)
               (list 'tmux-target-type 'pane
                     'tmux-target-id pane-id
                     'mouse-face 'highlight
                     'help-echo "RET: select tmux pane")))))
        (goto-char (point-min))))))

(defun tmux-cc-manager-visit ()
  "Visit the tmux target at point in the manager buffer."
  (interactive)
  (let ((target-type (get-text-property (point) 'tmux-target-type))
        (target-id (get-text-property (point) 'tmux-target-id)))
    (pcase target-type
      ('window
       (tmux-cc-send-command (format "select-window -t %s" (tmux-cc--tmux-target target-id))))
      ('pane
       (tmux-cc-send-command (format "select-pane -t %s" (tmux-cc--tmux-target target-id))))
      (_
       (user-error "No tmux target on this line")))))

(provide 'tmux-cc)
;;; tmux-cc.el ends here
