;;; tmux-cc-tests.el --- Tests for tmux-cc -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(setq load-prefer-newer t)
(require 'tmux-cc)

(defun tmux-cc-test--cleanup ()
  "Clean up tmux-cc test state."
  (when (process-live-p tmux-cc-process)
    (delete-process tmux-cc-process))
  (maphash
   (lambda (_pane-id buffer)
     (when (buffer-live-p buffer)
       (when-let ((proc (get-buffer-process buffer)))
         (delete-process proc))
       (kill-buffer buffer)))
   tmux-cc-panes)
  (clrhash tmux-cc-panes)
  (clrhash tmux-cc--pane-history-state)
  (clrhash tmux-cc--pane-history-pending-output)
  (setq tmux-cc-process nil
        tmux-cc--buffer ""
        tmux-cc--cmd-queue nil
        tmux-cc--current-cmd-lines nil
        tmux-cc--in-cmd nil))

(defmacro tmux-cc-test--with-clean-state (&rest body)
  "Run BODY with a clean tmux-cc state."
  `(unwind-protect
       (progn
         (tmux-cc-test--cleanup)
         ,@body)
     (tmux-cc-test--cleanup)
     (delete-other-windows)))

(ert-deftest tmux-cc-parse-layout-tree ()
  (tmux-cc-test--with-clean-state
   (let* ((layout "b7c7,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}")
          (tree (tmux-cc-parse-layout-string layout))
          (children (nth 6 tree))
          (right (cadr children)))
     (should (eq (nth 0 tree) 'horizontal))
     (should (= (length children) 2))
     (should (equal (nth 5 (car children)) "1"))
     (should (eq (nth 0 right) 'vertical))
     (should (equal (mapcar (lambda (node) (format "%%%s" (nth 5 node)))
                            (nth 6 right))
                    '("%2" "%3"))))))

(ert-deftest tmux-cc-command-block-callback ()
  (tmux-cc-test--with-clean-state
   (let (result)
     (setq tmux-cc--cmd-queue
           (list (lambda (lines)
                   (setq result lines))))
     (tmux-cc--handle-line "%begin 12 1 0")
     (tmux-cc--handle-line "alpha")
     (tmux-cc--handle-line "beta")
     (tmux-cc--handle-line "%end 12 1 0")
     (should (equal result '("alpha" "beta"))))))

(ert-deftest tmux-cc-filter-strips-control-mode-wrapper ()
  (tmux-cc-test--with-clean-state
   (let ((process (make-process
                   :name "tmux-cc-test-control"
                   :buffer (generate-new-buffer "*tmux-cc-test-control*")
                   :command '("sleep" "1000000")))
         result)
     (unwind-protect
         (progn
           (setq tmux-cc--cmd-queue
                 (list (lambda (lines)
                         (setq result lines))))
           (tmux-cc--filter process "\eP1000p%begin 12 1 0\r\nalpha\r\n%end 12 1 0\r\n\e\\")
           (should (equal result '("alpha")))
           (should (equal tmux-cc--buffer "")))
       (when (process-live-p process)
         (delete-process process))
       (when (buffer-live-p (process-buffer process))
         (kill-buffer (process-buffer process)))))))

(ert-deftest tmux-cc-output-reaches-pane-buffer ()
  (tmux-cc-test--with-clean-state
   (let* ((buffer (get-buffer-create "*tmux-cc-test-pane*"))
          (proc (make-process
                 :name "tmux-cc-test-pane"
                 :buffer buffer
                 :command '("sleep" "10")
                 :connection-type 'pipe)))
     (puthash "%9" buffer tmux-cc-panes)
     (unwind-protect
         (cl-letf (((symbol-function 'tmux-cc--pane-emulate-terminal)
                    (lambda (target-proc string)
                      (with-current-buffer (process-buffer target-proc)
                        (goto-char (point-max))
                        (insert string)))))
           (tmux-cc--handle-output "%9" "hello\\040world")
           (with-current-buffer buffer
             (should (string-match-p "hello world"
                                     (buffer-substring-no-properties
                                      (point-min) (point-max))))))
       (when (process-live-p proc)
         (delete-process proc))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(ert-deftest tmux-cc-input-is-routed-back-to-tmux ()
  (tmux-cc-test--with-clean-state
   (let* ((buffer (get-buffer-create "*tmux-cc-test-pane*"))
          (proc (make-process
                 :name "tmux-cc-test-pane"
                 :buffer buffer
                 :command '("sleep" "10")
                 :connection-type 'pipe))
          (tmux-cc-process (make-process
                            :name "tmux-cc-test"
                            :buffer nil
                            :command '("sleep" "1000000")))
          captured)
     (process-put proc 'tmux-cc-pane-id "%5")
     (cl-letf (((symbol-function 'tmux-cc--send-keys)
                (lambda (pane-id string)
                  (push (list pane-id string) captured))))
       (unwind-protect
           (progn
             (process-send-string proc "xyz")
             (process-send-string proc "\n"))
         (when (process-live-p proc)
           (delete-process proc))
         (delete-process tmux-cc-process)))
     (should (equal (nreverse captured) '(("%5" "xyz") ("%5" "\n")))))))

(ert-deftest tmux-cc-control-keys-route-to-tmux ()
  (tmux-cc-test--with-clean-state
   (let ((buffer (get-buffer-create "*tmux-cc-test-pane*"))
         (proc (make-process
                :name "tmux-cc-test-pane"
                :buffer nil
                :command '("sleep" "10")
                :connection-type 'pipe))
         captured)
     (with-current-buffer buffer
       (set-process-buffer proc buffer))
     (process-put proc 'tmux-cc-pane-id "%5")
     (cl-letf (((symbol-function 'tmux-cc--send-keys)
                (lambda (pane-id string)
                  (push (list pane-id string) captured))))
       (unwind-protect
           (with-current-buffer buffer
             (dolist (binding tmux-cc--control-keys)
               (call-interactively
                (tmux-cc--control-key-command (cdr binding)))))
         (when (process-live-p proc)
           (delete-process proc))
         (when (buffer-live-p buffer)
           (kill-buffer buffer))))
     (should (equal (nreverse captured)
                    '(("%5" "\C-c")
                      ("%5" "\C-d")
                      ("%5" "\C-z")
                      ("%5" "\C-\\")))))))

(ert-deftest tmux-cc-preserves-window-management-bindings ()
  (tmux-cc-test--with-clean-state
   (let ((original (lookup-key (current-global-map) (kbd "C-\\"))))
     (unwind-protect
         (progn
           (global-set-key (kbd "C-\\") #'other-window)
           (with-temp-buffer
             (tmux-cc-pane-mode 1)
             (should (eq (key-binding (kbd "C-\\")) #'other-window))))
       (global-set-key (kbd "C-\\") original)))))

(ert-deftest tmux-cc-apply-layout-creates-window-tree ()
  (tmux-cc-test--with-clean-state
   (let ((tree (tmux-cc-parse-layout-string
                "abcd,90x30,0,0{30x30,0,0,1,59x30,31,0[59x15,31,0,2,59x14,31,16,3]}")))
     (delete-other-windows)
     (tmux-cc-apply-layout tree (selected-window))
     (should (= (length (window-list)) 3))
     (should (equal
              (sort (mapcar (lambda (window)
                              (process-get
                               (get-buffer-process (window-buffer window))
                               'tmux-cc-pane-id))
                            (window-list))
                    #'string<)
              '("%1" "%2" "%3"))))))

;;; tmux-cc-tests.el ends here
