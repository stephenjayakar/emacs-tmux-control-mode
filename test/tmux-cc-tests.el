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

(ert-deftest tmux-cc-output-reaches-pane-buffer ()
  (tmux-cc-test--with-clean-state
   (tmux-cc--handle-output "%9" "hello\\040world")
   (with-current-buffer (tmux-cc--pane-buffer "%9")
     (should (string-match-p "hello world"
                             (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest tmux-cc-input-is-routed-back-to-tmux ()
  (tmux-cc-test--with-clean-state
   (let* ((buffer (tmux-cc--pane-buffer "%5"))
          (proc (get-buffer-process buffer))
          (tmux-cc-process (make-process
                            :name "tmux-cc-test"
                            :buffer nil
                            :command '("sleep" "1000000")))
          captured)
     (cl-letf (((symbol-function 'tmux-cc--send-keys)
                (lambda (pane-id string)
                  (push (list pane-id string) captured))))
       (unwind-protect
           (with-current-buffer buffer
             (funcall term-input-sender proc "xyz"))
         (delete-process tmux-cc-process)))
     (should (equal (nreverse captured) '(("%5" "xyz") ("%5" "\n")))))))

(ert-deftest tmux-cc-line-mode-control-keys-route-to-tmux ()
  (tmux-cc-test--with-clean-state
   (let ((buffer (tmux-cc--pane-buffer "%5"))
         captured)
     (cl-letf (((symbol-function 'tmux-cc--send-keys)
                (lambda (pane-id string)
                  (push (list pane-id string) captured))))
       (with-current-buffer buffer
         (term-line-mode)
         (dolist (key '("C-c C-c" "C-c C-d" "C-c C-z" "C-c C-\\"))
           (call-interactively (key-binding (kbd key))))))
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
           (with-current-buffer (tmux-cc--pane-buffer "%7")
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
