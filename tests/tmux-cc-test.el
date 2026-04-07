;;; tmux-cc-test.el --- Tests for tmux-cc -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'tmux-cc)

(ert-deftest tmux-cc-parse-layout-string-test ()
  (let ((node (tmux-cc-parse-layout-string "b25f,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")))
    (should (equal (car node) 'horizontal))
    (should (= (length (nth 6 node)) 2))
    (should (equal (mapcar (lambda (child) (nth 5 child)) (nth 6 node))
                   '("1" "2")))))

(ert-deftest tmux-cc-decode-octal-test ()
  (should (equal (tmux-cc--decode-octal "abc\\015\\012def\\134ghi")
                 "abc\r\ndef\\ghi")))

(ert-deftest tmux-cc-strip-osc-test ()
  (should (equal (tmux-cc--strip-osc (concat "abc" (string ?\e) "]2;title" (string ?\a) "def"))
                 "abcdef")))

(ert-deftest tmux-cc-strip-problematic-escapes-test ()
  (let ((input (concat "abc" (string ?\e) "=" "def" (string ?\e) ">" "ghi"
                       (string ?\e) "khello" (string ?\e) "\\" "jkl")))
    (should (equal (tmux-cc--strip-problematic-escapes input)
                   "abcdefghijkl"))))

(ert-deftest tmux-cc-setup-keybindings-test ()
  (let ((tmux-cc-focus-next-key "C-<tab>")
        (tmux-cc-focus-prev-key "C-S-<tab>")
        (tmux-cc-focus-other-key "C-x o")
        (tmux-cc-split-horizontal-key "C-t 3")
        (tmux-cc-split-vertical-key "C-t 2")
        (tmux-cc-new-window-key "C-t c")
        (tmux-cc-new-session-key "C-t S")
        (tmux-cc-manager-key "C-t t")
        (tmux-cc-command-key "C-t !")
        (tmux-cc-switch-window-key "C-t w")
        (tmux-cc-switch-session-key "C-t s")
        (tmux-cc-detach-key "C-t d")
        (tmux-cc-kill-pane-key "C-t k"))
    (tmux-cc-setup-keybindings)
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-<tab>"))
                #'tmux-cc-smart-next-window))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-S-<tab>"))
                #'tmux-cc-smart-previous-window))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-x o"))
                #'tmux-cc-focus-next-pane))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t 3"))
                #'tmux-cc-split-horizontal))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t 2"))
                #'tmux-cc-split-vertical))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t c"))
                #'tmux-cc-new-window))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t S"))
                #'tmux-cc-new-session))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t t"))
                #'tmux-cc-manager))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t !"))
                #'tmux-cc-command))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t k"))
                #'tmux-cc-kill-pane))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t w"))
                #'tmux-cc-switch-window))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t s"))
                #'tmux-cc-switch-session))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-t d"))
                #'tmux-cc-detach))))

(ert-deftest tmux-cc-render-manager-buffer-test ()
  (tmux-cc--render-manager-buffer
   '("main\t$1\t1\t1")
   '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
   '("main\t@1\t%1\t1\tzsh\t80x24"))
  (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
    (should (derived-mode-p 'tmux-cc-manager-mode))
    (should (string-match-p "Tmux Control" (buffer-string)))
    (should (string-match-p "Sessions" (buffer-string)))
    (should (string-match-p "Windows" (buffer-string)))
    (should (string-match-p "Panes" (buffer-string)))))

(ert-deftest tmux-cc-manager-line-target-test ()
  (tmux-cc--render-manager-buffer
   '("main\t$1\t1\t1")
   '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
   '("main\t@1\t%1\t1\tzsh\t80x24"))
  (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
    (goto-char (point-min))
    (search-forward "editor")
    (should (equal (tmux-cc--manager-line-target)
                   '(window "@1" "%1" "main:editor")))
    (goto-char (point-min))
    (search-forward "%1")
    (should (equal (tmux-cc--manager-line-target)
                   '(pane "%1" nil "@1/%1")))))

(ert-deftest tmux-cc-manager-target-pane-id-test ()
  (should (equal (tmux-cc--manager-target-pane-id 'pane "%9" nil) "%9"))
  (should (equal (tmux-cc--manager-target-pane-id 'window "@1" "%1") "%1"))
  (should (equal (tmux-cc--manager-target-pane-id 'session "main" "%3") "%3")))

(ert-deftest tmux-cc-manager-inline-preview-toggle-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (preview-buffer (get-buffer-create "*tmux-cc-preview*"))
         (tmux-cc-manager-preview-window-size 2))
    (puthash "%1" preview-buffer tmux-cc-panes)
    (unwind-protect
        (progn
          (with-current-buffer preview-buffer
            (erase-buffer)
            (insert "one\ntwo\nthree\n"))
          (tmux-cc--render-manager-buffer
           '("main\t$1\t1\t1")
           '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
           '("main\t@1\t%1\t1\tzsh\t80x24"))
          (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
            (goto-char (point-min))
            (search-forward "editor")
            (tmux-cc-manager-toggle-preview)
            (should (equal tmux-cc--manager-preview-pane-id "%1"))
            (should (equal tmux-cc--manager-preview-target-type 'window))
            (should (equal tmux-cc--manager-preview-target-id "@1"))
            (should (string-match-p (regexp-quote "Preview main:editor (%1)")
                                    (tmux-cc--manager-preview-rendered-string)))
            (should (string-match-p "two"
                                    (tmux-cc--manager-preview-rendered-string)))
            (should (string-match-p "three"
                                    (tmux-cc--manager-preview-rendered-string)))
            (should-not (string-match-p "one"
                                        (tmux-cc--manager-preview-rendered-string)))
            (tmux-cc-manager-toggle-preview)
            (should-not (tmux-cc--manager-preview-rendered-string))
            (should-not tmux-cc--manager-preview-pane-id)))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer))
      (tmux-cc-manager-hide-preview))))

(ert-deftest tmux-cc-manager-inline-preview-rerender-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (preview-buffer (get-buffer-create "*tmux-cc-preview*")))
    (puthash "%1" preview-buffer tmux-cc-panes)
    (unwind-protect
        (progn
          (with-current-buffer preview-buffer
            (erase-buffer)
            (insert "alpha\nbeta\n"))
          (tmux-cc--render-manager-buffer
           '("main\t$1\t1\t1")
           '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
           '("main\t@1\t%1\t1\tzsh\t80x24"))
          (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
            (goto-char (point-min))
            (search-forward "editor")
            (tmux-cc-manager-toggle-preview))
          (tmux-cc--render-manager-buffer
           '("main\t$1\t1\t1")
           '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
           '("main\t@1\t%1\t1\tzsh\t80x24"))
          (should (tmux-cc--manager-preview-rendered-string))
          (should (equal tmux-cc--manager-preview-target-type 'window))
          (should (equal tmux-cc--manager-preview-target-id "@1"))
          (should (equal tmux-cc--manager-preview-pane-id "%1")))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer))
      (tmux-cc-manager-hide-preview))))

(ert-deftest tmux-cc-manager-inline-preview-refreshes-with-output-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (preview-buffer (get-buffer-create "*tmux-cc-preview*"))
         (preview-process (make-process
                           :name "tmux-cc-preview"
                           :buffer preview-buffer
                           :command '("sleep" "10")
                           :connection-type 'pipe)))
    (puthash "%1" preview-buffer tmux-cc-panes)
    (unwind-protect
        (cl-letf (((symbol-function 'term-emulate-terminal)
                   (lambda (proc string)
                     (with-current-buffer (process-buffer proc)
                       (goto-char (point-max))
                       (insert string)))))
          (tmux-cc--render-manager-buffer
           '("main\t$1\t1\t1")
           '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
           '("main\t@1\t%1\t1\tzsh\t80x24"))
          (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
            (goto-char (point-min))
            (search-forward "editor")
            (tmux-cc-manager-toggle-preview))
          (should (string-match-p "No pane output yet"
                                  (tmux-cc--manager-preview-rendered-string)))
          (tmux-cc--handle-output "%1" "hello\\012world")
          (should (string-match-p "hello"
                                  (tmux-cc--manager-preview-rendered-string)))
          (should (string-match-p "world"
                                  (tmux-cc--manager-preview-rendered-string))))
      (ignore-errors
        (when (process-live-p preview-process)
          (delete-process preview-process)))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer))
      (tmux-cc-manager-hide-preview))))

(ert-deftest tmux-cc-reconcile-pane-buffers-hides-inline-preview-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (preview-buffer (get-buffer-create "*tmux-cc-preview*")))
    (puthash "%1" preview-buffer tmux-cc-panes)
    (unwind-protect
        (progn
          (with-current-buffer preview-buffer
            (erase-buffer)
            (insert "gone\n"))
          (tmux-cc--render-manager-buffer
           '("main\t$1\t1\t1")
           '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
           '("main\t@1\t%1\t1\tzsh\t80x24"))
          (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
            (goto-char (point-min))
            (search-forward "editor")
            (tmux-cc-manager-toggle-preview))
          (should (tmux-cc--manager-preview-rendered-string))
          (tmux-cc--reconcile-pane-buffers nil)
          (should-not (tmux-cc--manager-preview-rendered-string))
          (should-not tmux-cc--manager-preview-pane-id))
      (when (buffer-live-p preview-buffer)
        (kill-buffer preview-buffer))
      (tmux-cc-manager-hide-preview))))

(ert-deftest tmux-cc-apply-pane-history-replays-history-and-queued-output-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (tmux-cc--pane-history-state (make-hash-table :test 'equal))
         (tmux-cc--pane-history-pending-output (make-hash-table :test 'equal))
         (buffer (get-buffer-create "*tmux-cc-history*")))
    (puthash "%1" buffer tmux-cc-panes)
    (unwind-protect
        (let ((proc (make-process
                     :name "tmux-cc-history"
                     :buffer buffer
                     :command '("sleep" "10")
                     :connection-type 'pipe)))
          (puthash "%1" '("new output") tmux-cc--pane-history-pending-output)
          (cl-letf (((symbol-function 'term-emulate-terminal)
                     (lambda (target-proc text)
                       (with-current-buffer (process-buffer target-proc)
                         (goto-char (point-max))
                         (insert (replace-regexp-in-string "\r\n" "\n" text))))))
            (tmux-cc--apply-pane-history "%1" '("old 1" "old 2")))
          (with-current-buffer buffer
            (should (equal (buffer-string) "old 1\nold 2\nnew output")))
          (should (eq (gethash "%1" tmux-cc--pane-history-state) 'loaded))
          (should-not (gethash "%1" tmux-cc--pane-history-pending-output))
          (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest tmux-cc-request-pane-history-sends-capture-pane-test ()
  (let* ((tmux-cc-process t)
         (tmux-cc-panes (make-hash-table :test 'equal))
         (tmux-cc--pane-history-state (make-hash-table :test 'equal))
         (tmux-cc--pane-history-pending-output (make-hash-table :test 'equal))
         (tmux-cc-pane-history-lines 50)
         (buffer (get-buffer-create "*tmux-cc-history*"))
         (proc (make-process
                :name "tmux-cc-history"
                :buffer buffer
                :command '("sleep" "10")
                :connection-type 'pipe))
         sent-command)
    (puthash "%9" buffer tmux-cc-panes)
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p)
                   (lambda (_process) t))
                  ((symbol-function 'term-emulate-terminal)
                   (lambda (target-proc text)
                     (with-current-buffer (process-buffer target-proc)
                       (goto-char (point-max))
                       (insert (replace-regexp-in-string "\r\n" "\n" text)))))
                  ((symbol-function 'tmux-cc-send-command)
                   (lambda (cmd callback)
                     (setq sent-command cmd)
                     (funcall callback '("line a" "line b")))))
          (tmux-cc--request-pane-history "%9")
          (should (equal sent-command
                         "capture-pane -e -p -S -50 -E - -t '%9'"))
          (with-current-buffer buffer
            (should (equal (buffer-string) "line a\nline b\n")))
          (should (eq (gethash "%9" tmux-cc--pane-history-state) 'loaded)))
      (when (process-live-p proc)
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest tmux-cc-handle-output-queues-while-history-pending-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (tmux-cc--pane-history-state (make-hash-table :test 'equal))
         (tmux-cc--pane-history-pending-output (make-hash-table :test 'equal))
         (buffer (get-buffer-create "*tmux-cc-history*"))
         (proc (make-process
                :name "tmux-cc-history"
                :buffer buffer
                :command '("sleep" "10")
                :connection-type 'pipe)))
    (puthash "%2" buffer tmux-cc-panes)
    (puthash "%2" 'pending tmux-cc--pane-history-state)
    (unwind-protect
        (cl-letf (((symbol-function 'term-emulate-terminal)
                   (lambda (&rest _)
                     (error "term-emulate-terminal should not run while history pending"))))
          (tmux-cc--handle-output "%2" "hello\\012world")
          (should (equal (gethash "%2" tmux-cc--pane-history-pending-output)
                         '("hello\nworld"))))
      (when (process-live-p proc)
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest tmux-cc-handle-error-stops-session-test ()
  (let* ((tmux-cc-panes (make-hash-table :test 'equal))
         (process-buffer (generate-new-buffer "*tmux-cc-test*"))
         (pane-buffer (generate-new-buffer "tmux-pane %1"))
         (process (make-process
                   :name "tmux-cc-test"
                   :buffer process-buffer
                   :command '("sleep" "10")
                   :connection-type 'pipe))
         (tmux-cc-process process))
    (puthash "%1" pane-buffer tmux-cc-panes)
    (unwind-protect
        (progn
          (tmux-cc--handle-line "%error 1774820131 324 1")
          (should (null tmux-cc-process))
          (should-not (process-live-p process))
          (should (= (hash-table-count tmux-cc-panes) 0))
          (should-not (buffer-live-p pane-buffer)))
      (ignore-errors
        (when (process-live-p process)
          (delete-process process)))
      (ignore-errors
        (when (buffer-live-p process-buffer)
          (kill-buffer process-buffer)))
      (ignore-errors
        (when (buffer-live-p pane-buffer)
          (kill-buffer pane-buffer))))))

(provide 'tmux-cc-test)
;;; tmux-cc-test.el ends here
