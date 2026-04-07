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
  '("C-x" "M-x" "C-t" "C-<tab>" "C-S-<tab>" "C-M-S-<tab>" "s-]" "s-{" "s-t" "s-w" "C-\\")
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

(defcustom tmux-cc-command-key "C-t !"
  "Key used in tmux pane buffers for `tmux-cc-command'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-split-horizontal-key "C-t 3"
  "Key used in tmux pane buffers for `tmux-cc-split-horizontal'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-split-vertical-key "C-t 2"
  "Key used in tmux pane buffers for `tmux-cc-split-vertical'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-new-window-key "C-t c"
  "Key used in tmux pane buffers for `tmux-cc-new-window'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-new-session-key "C-t S"
  "Key used in tmux pane buffers for `tmux-cc-new-session'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-manager-key "C-t t"
  "Key used in tmux pane buffers for `tmux-cc-manager'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-switch-window-key "C-t w"
  "Key used in tmux pane buffers for `tmux-cc-switch-window'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-switch-session-key "C-t s"
  "Key used in tmux pane buffers for `tmux-cc-switch-session'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-detach-key "C-t d"
  "Key used in tmux pane buffers for detaching the tmux client."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-kill-pane-key "C-t k"
  "Key used in tmux pane buffers for `tmux-cc-kill-pane'."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'tmux-cc)

(defcustom tmux-cc-manager-buffer-name "*tmux-control*"
  "Name of the tmux management buffer."
  :type 'string
  :group 'tmux-cc)

(defcustom tmux-cc-manager-help-buffer-name "*tmux-control-help*"
  "Name of the tmux manager help buffer."
  :type 'string
  :group 'tmux-cc)

(defcustom tmux-cc-pane-buffer-prefix "tmux-pane "
  "Prefix used when naming tmux pane buffers."
  :type 'string
  :group 'tmux-cc)

(defcustom tmux-cc-manager-preview-window-size 12
  "Maximum number of lines to show in the inline tmux manager preview."
  :type 'integer
  :group 'tmux-cc)

(defcustom tmux-cc-confirm-destructive-actions t
  "When non-nil, confirm destructive tmux actions from the manager."
  :type 'boolean
  :group 'tmux-cc)

(defcustom tmux-cc-default-command "tmux -CC attach"
  "Default shell command used by `tmux-cc-start'."
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

(defvar tmux-cc--manager-preview-overlay nil
  "Inline preview overlay for the tmux manager, when present.")

(defvar tmux-cc--manager-preview-pane-id nil
  "Pane id currently shown in the tmux manager preview.")

(defvar tmux-cc--manager-preview-target-type nil
  "Manager target type currently shown in the tmux manager preview.")

(defvar tmux-cc--manager-preview-target-id nil
  "Manager target id currently shown in the tmux manager preview.")

(defvar tmux-cc--manager-preview-label nil
  "Manager target label currently shown in the tmux manager preview.")

(defvar tmux-cc--manager-last-sessions nil
  "Last tmux session lines used to render the manager buffer.")

(defvar tmux-cc--manager-last-windows nil
  "Last tmux window lines used to render the manager buffer.")

(defvar tmux-cc--manager-last-panes nil
  "Last tmux pane lines used to render the manager buffer.")

(defface tmux-cc-manager-preview-header
  '((((background light)) :foreground "midnight blue" :weight bold)
    (t :foreground "light sky blue" :weight bold))
  "Face used for the tmux manager preview header."
  :group 'tmux-cc)

(defface tmux-cc-manager-preview
  '((((background light)) :foreground "gray25")
    (t :foreground "gray80"))
  "Face used for tmux manager preview contents."
  :group 'tmux-cc)

(defvar tmux-cc--deferred-bootstrap-timer nil
  "Idle timer used to defer layout bootstrap until tmux command traffic settles.")

(defvar tmux-cc--startup-refresh-pending nil
  "Non-nil when tmux-cc still needs to issue its first post-attach manager refresh.")

(defvar tmux-cc--startup-refresh-timer nil
  "Fallback timer for the initial tmux-cc manager refresh.")

(defvar tmux-cc-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'tmux-cc-manager-refresh)
    (define-key map (kbd "RET") #'tmux-cc-manager-visit)
    (define-key map (kbd "TAB") #'tmux-cc-manager-toggle-preview)
    (define-key map (kbd "<tab>") #'tmux-cc-manager-toggle-preview)
    (define-key map (kbd "h") #'tmux-cc-manager-help)
    (define-key map (kbd "?") #'tmux-cc-manager-help)
    (define-key map (kbd "k") #'tmux-cc-manager-delete)
    (define-key map (kbd "c") #'tmux-cc-manager-command)
    (define-key map (kbd "n") #'tmux-cc-manager-new-window)
    (define-key map (kbd "S") #'tmux-cc-manager-new-session)
    (define-key map (kbd "s") #'tmux-cc-switch-session)
    (define-key map (kbd "w") #'tmux-cc-switch-window)
    (define-key map (kbd "d") #'tmux-cc-manager-detach)
    (define-key map (kbd "q") #'quit-window)
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
  (tmux-cc--bind-pane-key tmux-cc-focus-next-key #'tmux-cc-smart-next-window)
  (tmux-cc--bind-pane-key tmux-cc-focus-prev-key #'tmux-cc-smart-previous-window)
  (tmux-cc--bind-pane-key tmux-cc-focus-other-key #'tmux-cc-focus-next-pane)
  (tmux-cc--bind-pane-key tmux-cc-command-key #'tmux-cc-command)
  (tmux-cc--bind-pane-key tmux-cc-split-horizontal-key #'tmux-cc-split-horizontal)
  (tmux-cc--bind-pane-key tmux-cc-split-vertical-key #'tmux-cc-split-vertical)
  (tmux-cc--bind-pane-key tmux-cc-new-window-key #'tmux-cc-new-window)
  (tmux-cc--bind-pane-key tmux-cc-new-session-key #'tmux-cc-new-session)
  (tmux-cc--bind-pane-key tmux-cc-manager-key #'tmux-cc-manager)
  (tmux-cc--bind-pane-key tmux-cc-switch-window-key #'tmux-cc-switch-window)
  (tmux-cc--bind-pane-key tmux-cc-switch-session-key #'tmux-cc-switch-session)
  (tmux-cc--bind-pane-key tmux-cc-detach-key #'tmux-cc-detach)
  (tmux-cc--bind-pane-key tmux-cc-kill-pane-key #'tmux-cc-kill-pane))

(tmux-cc-setup-keybindings)

(defun tmux-cc--tmux-target (target)
  "Quote tmux TARGET for command use."
  (format "'%s'" target))

(defun tmux-cc--bootstrap-current-layout ()
  "Query tmux for the current window layout and apply it in Emacs."
  (when (process-live-p tmux-cc-process)
    (tmux-cc-send-command
     "list-windows -F '#{window_active}\t#{window_id}\t#{window_layout}'"
     (lambda (lines)
       (let* ((selected-line
               (or (catch 'found
                     (dolist (line lines)
                       (when (string-prefix-p "1\t" line)
                         (throw 'found line))))
                   (car lines)))
              (parts (and selected-line (split-string selected-line "\t"))))
         (when (>= (length parts) 3)
           (tmux-cc--handle-layout-change (nth 1 parts) (nth 2 parts))))))))

(defun tmux-cc--schedule-bootstrap-current-layout (&optional delay)
  "Bootstrap the current tmux layout after pending commands drain.
When DELAY is non-nil, wait DELAY seconds before rechecking."
  (when (timerp tmux-cc--deferred-bootstrap-timer)
    (cancel-timer tmux-cc--deferred-bootstrap-timer))
  (setq tmux-cc--deferred-bootstrap-timer
        (run-at-time
         (or delay 0.05)
         nil
         (lambda ()
           (setq tmux-cc--deferred-bootstrap-timer nil)
           (when (process-live-p tmux-cc-process)
             (if (or tmux-cc--in-cmd tmux-cc--cmd-queue)
                 (tmux-cc--schedule-bootstrap-current-layout 0.05)
               (tmux-cc--bootstrap-current-layout)))))))

(defun tmux-cc--render-manager-closed (&optional reason)
  "Render the tmux manager in a disconnected state with optional REASON."
  (when (buffer-live-p (get-buffer tmux-cc-manager-buffer-name))
    (with-current-buffer (get-buffer tmux-cc-manager-buffer-name)
      (tmux-cc-manager-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Tmux Control\n" 'face 'bold))
        (insert (propertize "Session closed\n\n" 'face 'warning))
        (when reason
          (insert reason "\n\n"))
        (insert "Run `M-x tmux-cc-start` to reconnect.\n")
        (goto-char (point-min))))))

(defun tmux-cc--show-manager-buffer ()
  "Show the tmux manager buffer without forcing a refresh."
  (let ((buffer (get-buffer-create tmux-cc-manager-buffer-name)))
    (with-current-buffer buffer
      (tmux-cc-manager-mode)
      (setq-local revert-buffer-function #'tmux-cc-manager-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun tmux-cc--render-manager-connecting ()
  "Render the tmux manager in a startup/connecting state."
  (with-current-buffer (tmux-cc--show-manager-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "Tmux Control\n" 'face 'bold))
      (insert (propertize "Connecting...\n\n" 'face 'shadow))
      (insert "Waiting for tmux control mode to finish attaching.\n")
      (goto-char (point-min)))))

(defun tmux-cc--run-startup-refresh ()
  "Run the initial tmux manager refresh after attach completes."
  (when (timerp tmux-cc--startup-refresh-timer)
    (cancel-timer tmux-cc--startup-refresh-timer))
  (setq tmux-cc--startup-refresh-timer nil)
  (when tmux-cc--startup-refresh-pending
    (setq tmux-cc--startup-refresh-pending nil)
    (when (process-live-p tmux-cc-process)
      (tmux-cc-manager-refresh
       (lambda (&rest _)
         (tmux-cc--bootstrap-current-layout))))))

(defun tmux-cc--cleanup-session (&optional process reason)
  "Clean up tmux-cc state for PROCESS with optional REASON."
  (let ((target-process (or process tmux-cc-process)))
    (when (timerp tmux-cc--deferred-bootstrap-timer)
      (cancel-timer tmux-cc--deferred-bootstrap-timer))
    (setq tmux-cc--deferred-bootstrap-timer nil)
    (when (timerp tmux-cc--startup-refresh-timer)
      (cancel-timer tmux-cc--startup-refresh-timer))
    (setq tmux-cc--startup-refresh-timer nil
          tmux-cc--startup-refresh-pending nil)
    (tmux-cc-manager-hide-preview)
    (when (buffer-live-p (get-buffer tmux-cc-manager-help-buffer-name))
      (kill-buffer (get-buffer tmux-cc-manager-help-buffer-name)))
    (maphash
     (lambda (pane-id buffer)
       (when (buffer-live-p buffer)
         (when-let ((proc (get-buffer-process buffer)))
           (delete-process proc))
         (kill-buffer buffer))
       (remhash pane-id tmux-cc-panes))
     tmux-cc-panes)
    (clrhash tmux-cc-panes)
    (when (and target-process (buffer-live-p (process-buffer target-process)))
      (kill-buffer (process-buffer target-process)))
    (setq tmux-cc-process nil
          tmux-cc--buffer ""
          tmux-cc--cmd-queue nil
          tmux-cc--current-cmd-lines nil
          tmux-cc--in-cmd nil)
    (tmux-cc--render-manager-closed reason)))

(defun tmux-cc-stop (&optional reason)
  "Stop the active tmux control session with optional REASON."
  (interactive)
  (let ((process tmux-cc-process))
    (if (process-live-p process)
        (progn
          (delete-process process)
          (tmux-cc--cleanup-session process reason))
      (tmux-cc--cleanup-session process reason))))

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

(defun tmux-cc--ensure-layout-pane-buffers (node)
  "Ensure pane buffers exist for each pane in layout NODE."
  (let ((type (nth 0 node))
        (pane-id (nth 5 node))
        (children (nth 6 node)))
    (cond
     ((eq type 'pane)
      (let ((pane-id-str (format "%%%s" pane-id)))
        (unless (buffer-live-p (gethash pane-id-str tmux-cc-panes))
          (tmux-cc-create-pane pane-id-str))))
     (children
      (dolist (child children)
        (tmux-cc--ensure-layout-pane-buffers child))))))

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
   (list (read-shell-command "tmux command: " tmux-cc-default-command)))
  (when (process-live-p tmux-cc-process)
    (if (y-or-n-p "A tmux-cc process is already running. Kill it? ")
        (tmux-cc-stop "Replaced by a new tmux control session.")
      (user-error "tmux-cc process already running")))

  (setq tmux-cc--buffer "")
  (unless (hash-table-p tmux-cc-panes)
    (setq tmux-cc-panes (make-hash-table :test 'equal)))
  (clrhash tmux-cc-panes)
  (setq tmux-cc--startup-refresh-pending t)

  (setq tmux-cc-process
        (make-process
         :name "tmux-cc"
         :buffer (generate-new-buffer "*tmux-cc*")
         :command (split-string-and-unquote command)
         :connection-type 'pty
         :filter #'tmux-cc--filter
         :sentinel #'tmux-cc--sentinel))

  (tmux-cc--render-manager-connecting)
  (setq tmux-cc--startup-refresh-timer
        (run-at-time 0.2 nil #'tmux-cc--run-startup-refresh))
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
  (let ((reason (format "tmux-cc process %s" (string-trim event))))
    (unless (process-live-p tmux-cc-process)
      (tmux-cc--cleanup-session nil reason))
    (message "%s" reason)))

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
        (funcall cb (nreverse tmux-cc--current-cmd-lines)))
      (when (and (not cb) tmux-cc--startup-refresh-pending)
        (tmux-cc--run-startup-refresh))))

   ((string-prefix-p "%error " line)
    (setq tmux-cc--in-cmd nil)
    (let ((cb (pop tmux-cc--cmd-queue)))
      (when cb
        ;; Pass nil or the error lines to the callback if desired
        (funcall cb (nreverse tmux-cc--current-cmd-lines))))
    (tmux-cc-stop (format "tmux error: %s" line))
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
    (tmux-cc--schedule-bootstrap-current-layout)
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
        (term-emulate-terminal proc clean))))
  (when (equal pane-id tmux-cc--manager-preview-pane-id)
    (tmux-cc--manager-refresh-preview)))

(defun tmux-cc--handle-layout-change (_window-id layout-str)
  "Handle layout change for WINDOW-ID with new LAYOUT-STR."
  (message "Handling layout change: %s" layout-str)
  (let ((node (tmux-cc-parse-layout-string layout-str)))
    (tmux-cc--ensure-layout-pane-buffers node)
    (unless (with-current-buffer (window-buffer (selected-window))
              (derived-mode-p 'tmux-cc-manager-mode))
      ;; Apply layout to the selected window. First close others.
      (delete-other-windows)
      (tmux-cc-apply-layout node (selected-window)))))

(defun tmux-cc-create-pane (pane-id)
  "Create a term buffer for tmux PANE-ID."
  (let* ((buf-name (format "%s%s" tmux-cc-pane-buffer-prefix pane-id))
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

;;; --- Compatibility Cleanup For Old Window Advice ---

(defun tmux-cc--intercept-split-window-right (orig-fun &rest args)
  "Compatibility shim retained so reloading removes older split advice."
  (apply orig-fun args))

(defun tmux-cc--intercept-split-window-below (orig-fun &rest args)
  "Compatibility shim retained so reloading removes older split advice."
  (apply orig-fun args))

(defun tmux-cc--intercept-delete-window (orig-fun &optional window)
  "Compatibility shim retained so reloading removes older delete advice."
  (funcall orig-fun window))

(defun tmux-cc--intercept-delete-other-windows (orig-fun &optional window)
  "Compatibility shim retained so reloading removes older delete advice."
  (funcall orig-fun window))

(advice-remove 'split-window-right #'tmux-cc--intercept-split-window-right)
(advice-remove 'split-window-below #'tmux-cc--intercept-split-window-below)
(advice-remove 'delete-window #'tmux-cc--intercept-delete-window)
(advice-remove 'delete-other-windows #'tmux-cc--intercept-delete-other-windows)

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

(defun tmux-cc--current-pane-id-required ()
  "Return the current tmux pane id, signaling a user error when missing."
  (or (tmux-cc--current-pane-id)
      (user-error "Current buffer is not a tmux pane")))

(defun tmux-cc--pane-id-for-window (window)
  "Return the tmux pane id displayed in WINDOW, or nil."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (tmux-cc--current-pane-id))))

(defun tmux-cc--select-pane-id (pane-id)
  "Select tmux PANE-ID and mirror the selection in Emacs."
  (tmux-cc-send-command
   (format "select-pane -t %s" (tmux-cc--tmux-target pane-id))))

(defun tmux-cc--focus-window-pane (window)
  "Select tmux pane shown in WINDOW and move Emacs focus there."
  (let ((pane-id (tmux-cc--pane-id-for-window window)))
    (when pane-id
      (select-window window)
      (tmux-cc--select-pane-id pane-id)
      pane-id)))

(defun tmux-cc--sync-selected-window-to-tmux ()
  "Sync tmux focus to the selected Emacs window when it shows a tmux pane."
  (tmux-cc--focus-window-pane (selected-window)))

(defun tmux-cc--neighbor-pane-window (directions)
  "Return the first live tmux pane window found in DIRECTIONS."
  (catch 'found
    (dolist (direction directions)
      (let ((window (ignore-errors (windmove-find-other-window direction))))
        (when (tmux-cc--pane-id-for-window window)
          (throw 'found window))))))

(defun tmux-cc-split-horizontal ()
  "Split the current tmux pane horizontally."
  (interactive)
  (tmux-cc--run-command-and-refresh
   (format "split-window -h -t %s"
           (tmux-cc--tmux-target (tmux-cc--current-pane-id-required)))))

(defun tmux-cc-split-vertical ()
  "Split the current tmux pane vertically."
  (interactive)
  (tmux-cc--run-command-and-refresh
   (format "split-window -v -t %s"
           (tmux-cc--tmux-target (tmux-cc--current-pane-id-required)))))

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
  (or (tmux-cc--focus-window-pane (tmux-cc--neighbor-pane-window '(right)))
      (tmux-cc--select-pane "-R")))

(defun tmux-cc-focus-left ()
  "Focus the tmux pane to the left."
  (interactive)
  (or (tmux-cc--focus-window-pane (tmux-cc--neighbor-pane-window '(left)))
      (tmux-cc--select-pane "-L")))

(defun tmux-cc-focus-up ()
  "Focus the tmux pane above."
  (interactive)
  (or (tmux-cc--focus-window-pane (tmux-cc--neighbor-pane-window '(up)))
      (tmux-cc--select-pane "-U")))

(defun tmux-cc-focus-down ()
  "Focus the tmux pane below."
  (interactive)
  (or (tmux-cc--focus-window-pane (tmux-cc--neighbor-pane-window '(down)))
      (tmux-cc--select-pane "-D")))

(defun tmux-cc-focus-next-pane ()
  "Focus the next visible tmux pane in a layout-aware order."
  (interactive)
  (or (tmux-cc--focus-window-pane
       (tmux-cc--neighbor-pane-window '(right down left up)))
      (tmux-cc-send-command "select-pane -t:.+")))

(defun tmux-cc-focus-previous-pane ()
  "Focus the previous visible tmux pane in a layout-aware order."
  (interactive)
  (or (tmux-cc--focus-window-pane
       (tmux-cc--neighbor-pane-window '(left up right down)))
      (tmux-cc-send-command "select-pane -t:.-")))

(defun tmux-cc-smart-next-window ()
  "Move to the next Emacs window and sync tmux focus when needed."
  (interactive)
  (next-window-any-frame)
  (tmux-cc--sync-selected-window-to-tmux))

(defun tmux-cc-smart-previous-window ()
  "Move to the previous Emacs window and sync tmux focus when needed."
  (interactive)
  (previous-window-any-frame)
  (tmux-cc--sync-selected-window-to-tmux))

(defun tmux-cc-detach ()
  "Detach the active tmux client."
  (interactive)
  (tmux-cc-send-command "detach-client"))

(defun tmux-cc-switch-session (&optional session)
  "Switch to tmux SESSION.
When SESSION is nil, prompt interactively."
  (interactive)
  (if session
      (tmux-cc--run-command-and-refresh
       (format "switch-client -t %s" (tmux-cc--tmux-target session)))
    (tmux-cc-send-command
     "list-sessions -F '#{session_name}'"
     (lambda (lines)
       (if (not lines)
           (message "No sessions found or command failed.")
         (let ((selected-session
                (completing-read "Switch to session: " lines nil t)))
           (when selected-session
             (tmux-cc-switch-session selected-session))))))))

(defun tmux-cc-switch-window (&optional window-str)
  "Switch to tmux WINDOW-STR.
WINDOW-STR should look like \"session:window\" when passed directly.
When WINDOW-STR is nil, prompt interactively."
  (interactive)
  (if window-str
      (tmux-cc--run-command-and-refresh
       (format "select-window -t %s" (tmux-cc--tmux-target window-str)))
    (tmux-cc-send-command
     "list-windows -a -F '#{session_name}:#{window_name}'"
     (lambda (lines)
       (if (not lines)
           (message "No windows found or command failed.")
         (let ((selected-window
                (completing-read "Switch to window: " lines nil t)))
           (when selected-window
             (tmux-cc-switch-window selected-window))))))))

(defun tmux-cc--pane-buffer (pane-id)
  "Return the tmux pane buffer for PANE-ID, creating it if needed."
  (let ((buffer (gethash pane-id tmux-cc-panes)))
    (unless (buffer-live-p buffer)
      (setq buffer (tmux-cc-create-pane pane-id)))
    buffer))

(defun tmux-cc--display-pane-buffer (pane-id)
  "Display the tmux pane buffer for PANE-ID."
  (pop-to-buffer (tmux-cc--pane-buffer pane-id)))

(defun tmux-cc--refresh-manager-if-live ()
  "Refresh the tmux manager buffer when it exists."
  (when (buffer-live-p (get-buffer tmux-cc-manager-buffer-name))
    (with-current-buffer tmux-cc-manager-buffer-name
      (tmux-cc-manager-refresh))))

(defun tmux-cc--run-command-and-refresh (command &optional callback)
  "Run tmux COMMAND, then refresh tmux manager buffers.
If CALLBACK is non-nil, call it with tmux command output lines."
  (tmux-cc-send-command
   command
   (lambda (lines)
     (tmux-cc--bootstrap-current-layout)
     (when callback
       (funcall callback lines))
     (tmux-cc--refresh-manager-if-live))))

(defun tmux-cc-new-window (&optional name)
  "Create a new tmux window, optionally named NAME."
  (interactive
   (list (read-string "New window name (optional): ")))
  (tmux-cc--run-command-and-refresh
   (if (string-empty-p (or name ""))
       "new-window"
     (format "new-window -n %s" (tmux-cc--tmux-target name)))))

(defun tmux-cc-new-session (&optional name)
  "Create a new detached tmux session named NAME."
  (interactive
   (list (read-string "New session name: ")))
  (when (string-empty-p (or name ""))
    (user-error "Session name is required"))
  (tmux-cc--run-command-and-refresh
   (format "new-session -d -s %s" (tmux-cc--tmux-target name))))

(defun tmux-cc-kill-pane (pane-id)
  "Kill tmux pane PANE-ID."
  (interactive (list (or (tmux-cc--current-pane-id)
                         (read-string "Pane id: "))))
  (tmux-cc--run-command-and-refresh
   (format "kill-pane -t %s" (tmux-cc--tmux-target pane-id))
   (lambda (_)
     (let ((buffer (gethash pane-id tmux-cc-panes)))
       (when (buffer-live-p buffer)
         (when-let ((proc (get-buffer-process buffer)))
           (delete-process proc))
         (kill-buffer buffer))
       (remhash pane-id tmux-cc-panes)))))

(defun tmux-cc-kill-window (window-id)
  "Kill tmux window WINDOW-ID."
  (interactive (list (read-string "Window id: ")))
  (tmux-cc--run-command-and-refresh
   (format "kill-window -t %s" (tmux-cc--tmux-target window-id))))

(defun tmux-cc-kill-session (session-name)
  "Kill tmux session SESSION-NAME."
  (interactive (list (read-string "Session name: ")))
  (tmux-cc--run-command-and-refresh
   (format "kill-session -t %s" (tmux-cc--tmux-target session-name))))

(defun tmux-cc-manager (&optional callback)
  "Open the tmux management buffer.
When CALLBACK is non-nil, invoke it after the next manager refresh."
  (interactive)
  (let ((buffer (get-buffer-create tmux-cc-manager-buffer-name)))
    (with-current-buffer buffer
      (tmux-cc-manager-mode)
      (setq-local revert-buffer-function #'tmux-cc-manager-refresh))
    (pop-to-buffer buffer)
    (if (process-live-p tmux-cc-process)
        (tmux-cc-manager-refresh callback)
      (tmux-cc--render-manager-closed))))

(defun tmux-cc--pane-id-list-from-pane-lines (panes)
  "Return live pane ids from tmux PANE output lines."
  (let (ids)
    (dolist (line panes)
      (let ((parts (split-string line "\t")))
        (when (>= (length parts) 3)
          (push (nth 2 parts) ids))))
    ids))

(defun tmux-cc--reconcile-pane-buffers (panes)
  "Remove dead pane buffers using live tmux PANE output lines."
  (let* ((live-ids (tmux-cc--pane-id-list-from-pane-lines panes))
         (live-set (make-hash-table :test 'equal))
         dead-ids)
    (dolist (pane-id live-ids)
      (puthash pane-id t live-set))
    (maphash
     (lambda (pane-id _buffer)
       (unless (gethash pane-id live-set)
         (push pane-id dead-ids)))
     tmux-cc-panes)
    (dolist (pane-id dead-ids)
      (let ((buffer (gethash pane-id tmux-cc-panes)))
        (when (buffer-live-p buffer)
          (when-let ((proc (get-buffer-process buffer)))
            (delete-process proc))
          (kill-buffer buffer))
        (remhash pane-id tmux-cc-panes)
        (when (equal pane-id tmux-cc--manager-preview-pane-id)
          (tmux-cc-manager-hide-preview))))))

(defun tmux-cc--manager-window-pane-map (panes)
  "Return a hash table mapping tmux window ids to preview pane ids using PANES."
  (let ((active (make-hash-table :test 'equal))
        (fallback (make-hash-table :test 'equal))
        (result (make-hash-table :test 'equal)))
    (dolist (line panes)
      (pcase-let ((`(,_session ,window-id ,pane-id ,pane-active . ,_)
                   (split-string line "\t")))
        (unless (gethash window-id fallback)
          (puthash window-id pane-id fallback))
        (when (string= pane-active "1")
          (puthash window-id pane-id active))))
    (maphash (lambda (window-id pane-id)
               (puthash window-id pane-id result))
             fallback)
    (maphash (lambda (window-id pane-id)
               (puthash window-id pane-id result))
             active)
    result))

(defun tmux-cc--manager-session-pane-map (windows window-pane-map)
  "Return a hash table mapping session names to preview pane ids.
WINDOWS is tmux list-windows output.
WINDOW-PANE-MAP maps window ids to pane ids."
  (let ((fallback (make-hash-table :test 'equal))
        (result (make-hash-table :test 'equal)))
    (dolist (line windows)
      (pcase-let ((`(,session ,_window-name ,window-id ,window-active . ,_)
                   (split-string line "\t")))
        (unless (gethash session fallback)
          (puthash session (gethash window-id window-pane-map) fallback))
        (when (string= window-active "1")
          (puthash session (gethash window-id window-pane-map) result))))
    (maphash (lambda (session pane-id)
               (unless (gethash session result)
                 (puthash session pane-id result)))
             fallback)
    result))

(defun tmux-cc-manager-refresh (&optional callback &rest _)
  "Refresh the tmux management buffer.
When CALLBACK is non-nil, invoke it after the manager finishes rendering."
  (interactive)
  (unless (process-live-p tmux-cc-process)
    (tmux-cc--render-manager-closed "tmux-cc process is not running")
    (user-error "tmux-cc process is not running"))
  (tmux-cc-send-command
   "list-sessions -F '#{session_name}\t#{session_id}\t#{session_attached}\t#{session_windows}'"
   (lambda (sessions)
     (tmux-cc-send-command
   "list-windows -a -F '#{session_name}\t#{window_name}\t#{window_id}\t#{window_active}\t#{window_layout}\t#{pane_id}'"
      (lambda (windows)
        (tmux-cc-send-command
         "list-panes -a -F '#{session_name}\t#{window_id}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_width}x#{pane_height}'"
         (lambda (panes)
           (tmux-cc--reconcile-pane-buffers panes)
           (tmux-cc--render-manager-buffer sessions windows panes)
           (when (functionp callback)
             (funcall callback sessions windows panes)))))))))

(defun tmux-cc--manager-line-target ()
  "Return tmux target metadata for the current manager line."
  (save-excursion
    (beginning-of-line)
    (let ((limit (line-end-position))
          target-type
          target-id
          pane-id
          label)
      (while (and (< (point) limit) (not target-type))
        (setq target-type (get-text-property (point) 'tmux-target-type)
              target-id (get-text-property (point) 'tmux-target-id)
              pane-id (get-text-property (point) 'tmux-pane-id)
              label (get-text-property (point) 'tmux-target-label))
        (unless target-type
          (forward-char 1)))
      (list target-type target-id pane-id label))))

(defun tmux-cc--manager-target-pane-id (target-type target-id pane-id)
  "Return a previewable pane id for manager TARGET-TYPE, TARGET-ID, and PANE-ID."
  (pcase target-type
    ('pane target-id)
    (_ pane-id)))

(defun tmux-cc--manager-preview-delete-overlay ()
  "Delete any legacy manager preview overlay.
Do not clear preview metadata."
  (when (overlayp tmux-cc--manager-preview-overlay)
    (delete-overlay tmux-cc--manager-preview-overlay))
  (setq tmux-cc--manager-preview-overlay nil))

(defun tmux-cc--manager-preview-live-p ()
  "Return non-nil when the tmux manager preview is active."
  (and tmux-cc--manager-preview-target-type
       tmux-cc--manager-preview-target-id
       tmux-cc--manager-preview-pane-id))

(defun tmux-cc--manager-preview-snapshot (pane-id)
  "Return a recent multiline snapshot string for tmux PANE-ID."
  (let ((buffer (gethash pane-id tmux-cc-panes))
        (max-lines (max 1 tmux-cc-manager-preview-window-size)))
    (cond
     ((not (buffer-live-p buffer))
      "[Pane buffer unavailable]")
     ((with-current-buffer buffer
        (= (point-min) (point-max)))
      "[No pane output yet]")
     (t
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (when (and (> (point) (point-min))
                     (eq (char-before) ?\n))
            (backward-char))
          (end-of-line)
          (let ((end (point)))
            (forward-line (- 1 max-lines))
            (buffer-substring-no-properties
             (line-beginning-position)
             end))))))))

(defun tmux-cc--manager-preview-string (pane-id label)
  "Return the inline preview string for tmux PANE-ID and LABEL."
  (let* ((snapshot (tmux-cc--manager-preview-snapshot pane-id))
         (lines (split-string snapshot "\n"))
         (header (propertize
                  (format "  | Preview %s (%s)\n"
                          (or label pane-id)
                          pane-id)
                  'face 'tmux-cc-manager-preview-header))
         (body
          (mapconcat
           (lambda (line)
             (propertize (format "  | %s" line)
                         'face 'tmux-cc-manager-preview))
           lines
           "\n")))
    (concat header body "\n")))

(defun tmux-cc--manager-preview-rendered-string ()
  "Return the rendered preview string currently visible in the manager buffer."
  (when (buffer-live-p (get-buffer tmux-cc-manager-buffer-name))
    (with-current-buffer tmux-cc-manager-buffer-name
      (save-excursion
        (goto-char (point-min))
        (let ((start nil)
              (end nil))
          (while (and (< (point) (point-max)) (not start))
            (when (get-text-property (point) 'tmux-preview)
              (setq start (line-beginning-position))
              (while (and (< (point) (point-max))
                          (get-text-property (point) 'tmux-preview))
                (forward-line 1))
              (setq end (point)))
            (unless start
              (forward-line 1)))
          (when (and start end)
            (buffer-substring-no-properties start end)))))))

(defun tmux-cc--manager-target-preview-active-p (target-type target-id)
  "Return non-nil when the active preview belongs under TARGET-TYPE/TARGET-ID."
  (and (equal target-type tmux-cc--manager-preview-target-type)
       (equal target-id tmux-cc--manager-preview-target-id)))

(defun tmux-cc--manager-insert-preview-block (pane-id label)
  "Insert an inline preview block for PANE-ID and LABEL at point."
  (let ((block (tmux-cc--manager-preview-string pane-id label)))
    (add-text-properties 0 (length block) '(tmux-preview t rear-nonsticky t) block)
    (insert block)))

(defun tmux-cc--manager-find-target (target-type target-id)
  "Move point to manager TARGET-TYPE and TARGET-ID and return its metadata."
  (goto-char (point-min))
  (catch 'found
    (while (< (point) (point-max))
      (pcase-let ((`(,candidate-type ,candidate-id ,pane-id ,label)
                   (tmux-cc--manager-line-target)))
        (when (and (eq candidate-type target-type)
                   (equal candidate-id target-id))
          (throw 'found
                 (list candidate-type candidate-id pane-id label))))
      (forward-line 1))
    nil))

(defun tmux-cc--manager-set-preview (target-type target-id pane-id label)
  "Store preview metadata for manager TARGET-TYPE, TARGET-ID, PANE-ID, and LABEL."
  (tmux-cc--manager-preview-delete-overlay)
  (setq tmux-cc--manager-preview-target-type target-type
        tmux-cc--manager-preview-target-id target-id
        tmux-cc--manager-preview-pane-id pane-id
        tmux-cc--manager-preview-label label))

(defun tmux-cc--manager-clear-preview-state ()
  "Clear the tmux manager preview state without rerendering."
  (tmux-cc--manager-preview-delete-overlay)
  (setq tmux-cc--manager-preview-target-type nil
        tmux-cc--manager-preview-target-id nil
        tmux-cc--manager-preview-label nil
        tmux-cc--manager-preview-pane-id nil))

(defun tmux-cc--manager-rerender ()
  "Rerender the manager buffer from the last fetched tmux data."
  (when (and (buffer-live-p (get-buffer tmux-cc-manager-buffer-name))
             tmux-cc--manager-last-sessions
             tmux-cc--manager-last-windows
             tmux-cc--manager-last-panes)
    (with-current-buffer tmux-cc-manager-buffer-name
      (let ((current-point (point)))
        (tmux-cc--render-manager-buffer
         tmux-cc--manager-last-sessions
         tmux-cc--manager-last-windows
         tmux-cc--manager-last-panes)
        (goto-char (min current-point (point-max)))))))

(defun tmux-cc--manager-refresh-preview ()
  "Refresh the active tmux manager preview overlay contents."
  (if (and (tmux-cc--manager-preview-live-p)
           tmux-cc--manager-preview-pane-id)
      (tmux-cc--manager-rerender)
    (tmux-cc--manager-clear-preview-state)))

(defun tmux-cc-manager-hide-preview ()
  "Hide the tmux manager preview, if present."
  (interactive)
  (tmux-cc--manager-clear-preview-state)
  (tmux-cc--manager-rerender))

(defun tmux-cc-manager-toggle-preview ()
  "Preview the tmux target at point inline in the manager buffer."
  (interactive)
  (pcase-let ((`(,target-type ,target-id ,pane-id ,_label)
               (tmux-cc--manager-line-target)))
    (let ((resolved-pane-id
           (tmux-cc--manager-target-pane-id target-type target-id pane-id)))
      (unless resolved-pane-id
        (user-error "No previewable tmux pane on this line"))
      (if (and (tmux-cc--manager-preview-live-p)
               (equal resolved-pane-id tmux-cc--manager-preview-pane-id))
          (tmux-cc-manager-hide-preview)
        (tmux-cc--manager-set-preview
         target-type target-id resolved-pane-id
         (or (nth 3 (tmux-cc--manager-line-target))
             target-id))
        (tmux-cc--manager-rerender)))))

(defun tmux-cc-manager-help ()
  "Show available tmux manager commands."
  (interactive)
  (let ((buffer (get-buffer-create tmux-cc-manager-help-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert "Tmux Control Manager\n\n")
        (insert "RET  Visit the tmux target at point\n")
        (insert "TAB  Preview the pane for the current line\n")
        (insert "g    Refresh sessions, windows, and panes\n")
        (insert "h/?  Show this help buffer\n")
        (insert "k    Kill the target at point (pane, window, or session)\n")
        (insert "n    Create a new tmux window\n")
        (insert "S    Create a new detached tmux session\n")
        (insert "c    Run an arbitrary tmux command\n")
        (insert "s    Interactive session switch\n")
        (insert "w    Interactive window switch\n")
        (insert "d    Detach the active tmux client\n")
        (insert "\nFocus keys\n")
        (insert (format "%-8s next visible tmux pane\n"
                        (or tmux-cc-focus-next-key "disabled")))
        (insert (format "%-8s previous visible tmux pane\n"
                        (or tmux-cc-focus-prev-key "disabled")))
        (insert "\nPane-local keys\n")
        (insert (format "%-8s split current tmux pane horizontally\n"
                        (or tmux-cc-split-horizontal-key "disabled")))
        (insert (format "%-8s split current tmux pane vertically\n"
                        (or tmux-cc-split-vertical-key "disabled")))
        (insert (format "%-8s create a new tmux window\n"
                        (or tmux-cc-new-window-key "disabled")))
        (insert (format "%-8s create a new detached tmux session\n"
                        (or tmux-cc-new-session-key "disabled")))
        (insert (format "%-8s open the tmux manager\n"
                        (or tmux-cc-manager-key "disabled")))
        (insert (format "%-8s kill the current tmux pane\n"
                        (or tmux-cc-kill-pane-key "disabled")))
        (insert "q    Quit the current manager/help window\n")))
    (display-buffer buffer)))

(defun tmux-cc-manager-command (command)
  "Run arbitrary tmux COMMAND from the manager and refresh."
  (interactive "sTmux command: ")
  (tmux-cc--run-command-and-refresh command))

(defun tmux-cc-manager-new-window ()
  "Create a new tmux window from the manager."
  (interactive)
  (call-interactively #'tmux-cc-new-window))

(defun tmux-cc-manager-new-session ()
  "Create a new detached tmux session from the manager."
  (interactive)
  (call-interactively #'tmux-cc-new-session))

(defun tmux-cc-manager-detach ()
  "Detach the active tmux client from the manager."
  (interactive)
  (tmux-cc-manager-hide-preview)
  (tmux-cc-detach))

(defun tmux-cc--manager-target-description (target-type target-id label)
  "Return a human-readable description for TARGET-TYPE, TARGET-ID, and LABEL."
  (pcase target-type
    ('session (format "session %s" (or label target-id)))
    ('window (format "window %s" (or label target-id)))
    ('pane (format "pane %s" target-id))
    (_ "target")))

(defun tmux-cc-manager-delete ()
  "Kill the tmux target at point."
  (interactive)
  (pcase-let ((`(,target-type ,target-id ,_pane-id ,label)
               (tmux-cc--manager-line-target)))
    (let ((description (tmux-cc--manager-target-description
                        target-type target-id label)))
      (unless target-type
        (user-error "No tmux target on this line"))
      (when (or (not tmux-cc-confirm-destructive-actions)
                (yes-or-no-p (format "Kill %s? " description)))
        (tmux-cc-manager-hide-preview)
        (pcase target-type
          ('pane
           (tmux-cc-kill-pane target-id))
          ('window
           (tmux-cc-kill-window target-id))
          ('session
           (tmux-cc-kill-session target-id))
          (_
           (user-error "Unsupported tmux target type: %s" target-type)))
        (message "Killed %s" description)))))

(defun tmux-cc--render-manager-buffer (sessions windows panes)
  "Render tmux manager buffer using SESSIONS, WINDOWS, and PANES output."
  (setq tmux-cc--manager-last-sessions sessions
        tmux-cc--manager-last-windows windows
        tmux-cc--manager-last-panes panes)
  (let ((buffer (get-buffer-create tmux-cc-manager-buffer-name)))
    (with-current-buffer buffer
      (tmux-cc-manager-mode)
      (let ((inhibit-read-only t))
        (tmux-cc--manager-preview-delete-overlay)
        (let* ((window-pane-map (tmux-cc--manager-window-pane-map panes))
               (session-pane-map
                (tmux-cc--manager-session-pane-map windows window-pane-map)))
          (erase-buffer)
          (insert (propertize "Tmux Control\n" 'face 'bold))
          (insert (propertize
                   "RET visit, TAB preview, g refresh, h help, k kill, n new-window, S new-session, c command, d detach\n"
                   'face 'shadow))
          (insert (propertize
                   (format "Pane keys: %s next, %s previous, %s manager, %s kill, %s split-right, %s split-below, %s command\n\n"
                           (or tmux-cc-focus-next-key "disabled")
                           (or tmux-cc-focus-prev-key "disabled")
                           (or tmux-cc-manager-key "disabled")
                           (or tmux-cc-kill-pane-key "disabled")
                           (or tmux-cc-split-horizontal-key "disabled")
                           (or tmux-cc-split-vertical-key "disabled")
                           (or tmux-cc-command-key "disabled"))
                   'face 'shadow))
          (insert (propertize "Sessions\n" 'face 'underline))
          (dolist (line sessions)
            (pcase-let ((`(,session-name ,session-id ,attached ,window-count)
                         (split-string line "\t")))
              (let ((start (point))
                    (pane-id (gethash session-name session-pane-map)))
                (insert (format "%s %-16s %-6s %2s windows attached:%s\n"
                                (if (and attached (not (string= attached "0"))) "*" " ")
                                session-name
                                session-id
                                window-count
                                attached))
                (add-text-properties
                 start (point)
                 (list 'tmux-target-type 'session
                       'tmux-target-id session-name
                       'tmux-pane-id pane-id
                       'tmux-target-label session-name
                       'mouse-face 'highlight
                       'help-echo "RET: switch to tmux session"))
                (when (tmux-cc--manager-target-preview-active-p 'session session-name)
                  (tmux-cc--manager-insert-preview-block pane-id session-name)))))
          (insert "\n")
          (insert (propertize "Windows\n" 'face 'underline))
          (dolist (line windows)
            (pcase-let ((`(,session ,window-name ,window-id ,active ,layout ,pane-id)
                         (split-string line "\t")))
              (let ((start (point))
                    (resolved-pane-id (or (gethash window-id window-pane-map) pane-id))
                    (label (format "%s:%s" session window-name)))
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
                       'tmux-pane-id resolved-pane-id
                       'tmux-target-label label
                       'mouse-face 'highlight
                       'help-echo "RET: select tmux window"))
                (when (tmux-cc--manager-target-preview-active-p 'window window-id)
                  (tmux-cc--manager-insert-preview-block resolved-pane-id label)))))
          (insert "\n")
          (insert (propertize "Panes\n" 'face 'underline))
          (dolist (line panes)
            (pcase-let ((`(,session ,window-id ,pane-id ,active ,command ,size)
                         (split-string line "\t")))
              (let ((start (point))
                    (label (format "%s/%s" window-id pane-id)))
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
                       'tmux-target-label label
                       'mouse-face 'highlight
                       'help-echo "RET: select tmux pane"))
                (when (tmux-cc--manager-target-preview-active-p 'pane pane-id)
                  (tmux-cc--manager-insert-preview-block pane-id label)))))
          (goto-char (point-min)))))))

(defun tmux-cc-manager-visit ()
  "Visit the tmux target at point in the manager buffer."
  (interactive)
  (pcase-let ((`(,target-type ,target-id ,pane-id ,_label)
               (tmux-cc--manager-line-target)))
    (pcase target-type
      ('session
       (when pane-id
         (tmux-cc--display-pane-buffer pane-id))
       (tmux-cc-send-command
        (format "switch-client -t %s" (tmux-cc--tmux-target target-id))
        (lambda (_)
          (tmux-cc--bootstrap-current-layout)
          (tmux-cc--refresh-manager-if-live)
          (when pane-id
            (tmux-cc--display-pane-buffer pane-id)))))
      ('window
       (when pane-id
         (tmux-cc--display-pane-buffer pane-id))
       (tmux-cc-send-command
        (format "select-window -t %s" (tmux-cc--tmux-target target-id))
        (lambda (_)
          (tmux-cc--bootstrap-current-layout)
          (tmux-cc--refresh-manager-if-live)
          (when pane-id
            (tmux-cc--display-pane-buffer pane-id)))))
      ('pane
       (tmux-cc--display-pane-buffer target-id)
       (tmux-cc-send-command
        (format "select-pane -t %s" (tmux-cc--tmux-target target-id))
        (lambda (_)
          (tmux-cc--bootstrap-current-layout)
          (tmux-cc--refresh-manager-if-live)
          (tmux-cc--display-pane-buffer target-id))))
      (_
       (user-error "No tmux target on this line")))))

(provide 'tmux-cc)
;;; tmux-cc.el ends here
