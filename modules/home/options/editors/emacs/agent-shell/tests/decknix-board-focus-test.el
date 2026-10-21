;;; decknix-board-focus-test.el --- The sidebar's board focus -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-board "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; The focus narrows the sidebar to one board through the board's own
;; membership rule: sessions, repositories and paths, the count of
;; sessions needing you elsewhere, the memo that keeps it off the paint
;; path, the `F' command, and the attention jump's opt-in respect for it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-board-focus)
(require 'decknix-board-scope-test)

;; --- the sidebar focus ---------------------------------------------------

(defmacro decknix-board-scope-test-focus (board &rest body)
  "Run BODY with the sidebar focused on BOARD, read from a temporary file."
  (declare (indent 1))
  `(let ((decknix-board-directory (make-temp-file "boards" t))
         (decknix-board-focus-name nil)
         (decknix-board-focus--cache nil)
         (decknix-board-focus--memo (make-hash-table :test 'equal)))
     (unwind-protect
         (decknix-board-scope-test-isolated
          (cl-letf (((symbol-function 'decknix--sidebar-state-write) #'ignore)
                    ((symbol-function 'agent-shell-workspace-sidebar-refresh) #'ignore))
            (decknix-board-write ,board)
            (decknix-board-focus-set (plist-get ,board :name))
            ,@body))
       (delete-directory decknix-board-directory t))))

(defconst decknix-board-scope-test--pilot
  '(:name "us-pilot" :title "US Pilot" :tags-any ("bramlett" "us" "acker")
    :repos ("UpsideRealty/followupboss-integration" "UpsideRealty/upside")
    :match both
    :github (:repo "UpsideRealty/followupboss-integration")))

(ert-deftest decknix-board-scope-test-focus-filters-sessions-repos-and-paths ()
  (decknix-board-scope-test-focus decknix-board-scope-test--pilot
    (let ((decknix-board-session-repos-function
           (lambda (s) (if (member "fub" (nth 1 s)) '("followupboss-integration") '("other")))))
      (should (decknix-board-focus-active-p))
      (should (equal (decknix-board-focus-title) "US Pilot"))
      (should (equal (mapcar #'car
                             (decknix-board-focus-sessions
                              (list (decknix-board-scope-test--session "in" '("bramlett" "fub"))
                                    (decknix-board-scope-test--session "untagged" '("fub"))
                                    (decknix-board-scope-test--session "elsewhere" '("bramlett")))))
                     '("in")))
      (should (decknix-board-focus-repo-p "UpsideRealty/upside"))
      (should-not (decknix-board-focus-repo-p "UpsideRealty/reapit-service"))
      (should (decknix-board-focus-path-p "/c/upside-worktrees/HX-1"))
      (should-not (decknix-board-focus-path-p "/c/reapit-service")))))

(ert-deftest decknix-board-scope-test-focus-counts-attention-elsewhere ()
  (decknix-board-scope-test-focus decknix-board-scope-test--pilot
    (let ((decknix-board-session-repos-function (lambda (_s) '("upside"))))
      (should (= 2 (decknix-board-focus-elsewhere-count
                    (list (decknix-board-scope-test--session "a" '("bramlett") "asking")
                          (decknix-board-scope-test--session "b" '("x") "waiting")
                          (decknix-board-scope-test--session "c" '("y") "netfail")
                          (decknix-board-scope-test--session "d" '("z") "working"))))))))

(ert-deftest decknix-board-scope-test-focus-memoises-membership ()
  (decknix-board-scope-test-focus decknix-board-scope-test--pilot
    (let* ((asked 0)
           (decknix-board-session-repos-function
            (lambda (_s) (cl-incf asked) '("upside")))
           (s (decknix-board-scope-test--session "a" '("us"))))
      (decknix-board-focus-sessions (list s))
      (decknix-board-focus-sessions (list (copy-sequence s)))
      (should (= 1 asked))
      ;; A state change does not invalidate it; a tag change does.
      (decknix-board-focus-sessions (list (decknix-board-scope-test--session "a" '("us") "asking")))
      (should (= 1 asked))
      (decknix-board-focus-sessions (list (decknix-board-scope-test--session "a" '("us" "x"))))
      (should (= 2 asked)))))

(ert-deftest decknix-board-scope-test-unfocused-passes-everything ()
  (let ((decknix-board-focus-name nil)
        (decknix-board-focus--cache nil))
    (should-not (decknix-board-focus-active-p))
    (should (equal (decknix-board-focus-sessions '(("a") ("b"))) '(("a") ("b"))))
    (should (decknix-board-focus-repo-p "any/thing"))
    (should (decknix-board-focus-path-p "/anywhere"))
    (should (= 0 (decknix-board-focus-elsewhere-count '(("a" nil nil "asking")))))))

(ert-deftest decknix-board-scope-test-focus-on-a-deleted-board-is-no-focus ()
  (let ((decknix-board-directory (make-temp-file "boards" t))
        (decknix-board-focus-name "gone")
        (decknix-board-focus--cache nil))
    (unwind-protect
        (progn (should-not (decknix-board-focus-active-p))
               (should (decknix-board-focus-repo-p "a/b")))
      (delete-directory decknix-board-directory t))))

(ert-deftest decknix-board-scope-test-focus-command-sets-clears-and-switches ()
  (decknix-board-scope-test-focus decknix-board-scope-test--pilot
    (decknix-board-write '(:name "hack" :title "Hack" :github (:repo "a/b")))
    (cl-letf (((symbol-function 'message) #'ignore))
      ;; Focused: F clears.
      (decknix-board-focus)
      (should-not decknix-board-focus-name)
      ;; Unfocused: F picks.
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "hack")))
        (decknix-board-focus))
      (should (equal decknix-board-focus-name "hack"))
      (should (equal (decknix-board-focus-title) "Hack"))
      ;; C-u F switches, and `none' clears.
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "us-pilot")))
        (decknix-board-focus '(4)))
      (should (equal decknix-board-focus-name "us-pilot"))
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "none")))
        (decknix-board-focus '(4)))
      (should-not decknix-board-focus-name))))

(ert-deftest decknix-board-scope-test-focus-sees-an-edited-definition ()
  (decknix-board-scope-test-focus decknix-board-scope-test--pilot
    (should (equal (decknix-board-focus-title) "US Pilot"))
    (decknix-board-write (plist-put (copy-sequence decknix-board-scope-test--pilot)
                                    :title "US Pilot 2"))
    (should (equal (decknix-board-focus-title) "US Pilot 2"))))

;; --- the attention jump --------------------------------------------------

(ert-deftest decknix-board-scope-test-attention-respects-focus-only-when-asked ()
  (let ((a (generate-new-buffer "focus-in"))
        (b (generate-new-buffer "focus-out")))
    (unwind-protect
        (decknix-board-scope-test-focus decknix-board-scope-test--pilot
          (let ((decknix-board-session-repos-function (lambda (_s) '("upside")))
                (decknix-attention--seen (make-hash-table :test 'eq :weakness 'key)))
            (cl-letf (((symbol-function 'decknix-attention--sessions)
                       (lambda ()
                         (list (decknix-board-scope-test--session (buffer-name a) '("us") "asking")
                               (decknix-board-scope-test--session (buffer-name b) '("x") "waiting")))))
              (should (eq decknix-attention-focus-function #'decknix-board-focus-sessions))
              (should (equal (decknix-attention-buffers) (list b a)))
              (should (equal (decknix-attention-buffers t) (list a)))
              (let ((decknix-attention-respect-focus nil))
                (should-not (decknix-attention-jump-respects-focus-p nil))
                (should-not (decknix-attention-jump-respects-focus-p '(4)))
                (should (decknix-attention-jump-respects-focus-p '(16))))
              (let ((decknix-attention-respect-focus t))
                (should (decknix-attention-jump-respects-focus-p nil))
                (should-not (decknix-attention-jump-respects-focus-p '(16)))))))
      (kill-buffer a)
      (kill-buffer b))))

(provide 'decknix-board-focus-test)
;;; decknix-board-focus-test.el ends here
