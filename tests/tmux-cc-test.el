;;; tmux-cc-test.el --- Tests for tmux-cc -*- lexical-binding: t; -*-

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
        (tmux-cc-command-key nil)
        (tmux-cc-switch-window-key nil)
        (tmux-cc-switch-session-key nil)
        (tmux-cc-detach-key nil))
    (tmux-cc-setup-keybindings)
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-<tab>"))
                #'tmux-cc-focus-right))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-S-<tab>"))
                #'tmux-cc-focus-left))
    (should (eq (lookup-key tmux-cc-pane-mode-map (kbd "C-x o"))
                #'tmux-cc-focus-next-pane))))

(ert-deftest tmux-cc-render-manager-buffer-test ()
  (tmux-cc--render-manager-buffer
   '("main\teditor\t@1\t1\tabcd,80x24,0,0,0\t%1")
   '("main\t@1\t%1\t1\tzsh\t80x24"))
  (with-current-buffer (get-buffer-create tmux-cc-manager-buffer-name)
    (should (derived-mode-p 'tmux-cc-manager-mode))
    (should (string-match-p "Tmux Control" (buffer-string)))
    (should (string-match-p "Windows" (buffer-string)))
    (should (string-match-p "Panes" (buffer-string)))))

(provide 'tmux-cc-test)
;;; tmux-cc-test.el ends here
