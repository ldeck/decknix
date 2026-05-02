;;; decknix-progress-sidebar-test.el --- Characterisation tests for sidebar badges -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-progress-sidebar "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the sidebar badge
;; renderer and its mtime-aware index cache.  Persisted state is
;; isolated to a tmp dir per test via
;; `decknix-test-with-tmp-progress-dir'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-progress)
(require 'decknix-progress-sidebar)

;; -- Empty / missing ------------------------------------------------

(ert-deftest decknix-progress--sidebar-badge/nil-conv-key-empty ()
  (decknix-test-with-tmp-progress-dir
    (should (equal "" (decknix-progress--sidebar-badge nil)))
    (should (equal "" (decknix-progress--sidebar-badge "")))))

(ert-deftest decknix-progress--sidebar-badge/missing-entry-empty ()
  (decknix-test-with-tmp-progress-dir
    (should (equal "" (decknix-progress--sidebar-badge "no-such-conv")))))

(ert-deftest decknix-progress--sidebar-badge/zero-count-and-none-empty ()
  (decknix-test-with-tmp-progress-dir
    (decknix-progress--persist
     "conv-empty"
     (list :conv-key "conv-empty"
           :updated 1.0
           :attention 'none
           :items nil))
    ;; Cache cleared per `decknix-test-with-tmp-progress-dir'.
    (should (equal "" (decknix-progress--sidebar-badge "conv-empty")))))

;; -- Populated badge ------------------------------------------------

(ert-deftest decknix-progress--sidebar-badge/format-and-help-echo ()
  (decknix-test-with-tmp-progress-dir
    (decknix-progress--persist
     "conv-amber"
     (list :conv-key "conv-amber"
           :updated 1.0
           :attention 'amber
           :items (list (list :id "x:1" :provider 'pr
                              :title "T" :state 'wip :attention 'amber)
                        (list :id "x:2" :provider 'pr
                              :title "U" :state 'wip :attention 'none))))
    (let ((badge (decknix-progress--sidebar-badge "conv-amber")))
      ;; Format is " [Nglyph]" with a leading space; amber → ◐.
      (should (equal " [2◐]" badge))
      ;; Properties: face + help-echo.
      (should (eq 'decknix-progress-attention-amber
                  (get-text-property 1 'face badge)))
      (should (string-match-p "2 progress items"
                              (or (get-text-property 1 'help-echo badge) ""))))))

(ert-deftest decknix-progress--sidebar-badge/glyph-per-attention ()
  (decknix-test-with-tmp-progress-dir
    (dolist (case '((red   "⚑") (amber "◐") (green "✓")))
      (let ((conv (format "conv-%s" (car case))))
        (decknix-progress--persist
         conv
         (list :conv-key conv :updated 1.0 :attention (car case)
               :items (list (list :id (format "%s:1" (car case))
                                  :provider 'pr
                                  :title "T" :state 'wip
                                  :attention (car case)))))
        (decknix-progress--index-cache-clear)
        (should (equal (format " [1%s]" (cadr case))
                       (decknix-progress--sidebar-badge conv)))))))

;; -- Mtime cache ----------------------------------------------------

(ert-deftest decknix-progress--read-index-cached/missing-returns-empty ()
  (decknix-test-with-tmp-progress-dir
    (let ((idx (decknix-progress--read-index-cached)))
      (should (hash-table-p idx))
      (should (= 0 (hash-table-count idx)))
      ;; Missing file leaves the cache cleared so the next write is read fresh.
      (should (null decknix-progress--index-cache)))))

(ert-deftest decknix-progress--index-cache-clear/zaps-cache ()
  (setq decknix-progress--index-cache (cons 'mtime (make-hash-table :test 'equal)))
  (decknix-progress--index-cache-clear)
  (should (null decknix-progress--index-cache)))

(ert-deftest decknix-progress--read-index-cached/honours-cache-on-same-mtime ()
  (decknix-test-with-tmp-progress-dir
    (decknix-progress--persist
     "conv-1"
     (list :conv-key "conv-1" :updated 1.0 :attention 'green
           :items (list (list :id "x:1" :provider 'pr
                              :title "T" :state 'done :attention 'green))))
    (let ((first (decknix-progress--read-index-cached)))
      (should (hash-table-p first))
      (should (= 1 (hash-table-count first)))
      ;; Tamper with the in-memory cache: if the second call honours the
      ;; cache it returns the tampered table; if it re-parses we'd see
      ;; the original size again.
      (puthash "synthetic" t first)
      (let ((second (decknix-progress--read-index-cached)))
        (should (gethash "synthetic" second))))))

;; -- Toggle ---------------------------------------------------------

(ert-deftest decknix-sidebar-toggle-progress/flips-var ()
  (let ((decknix--sidebar-show-progress t))
    (cl-letf (((symbol-function 'agent-shell-workspace-sidebar-refresh)
               (lambda (&rest _) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (decknix-sidebar-toggle-progress)
      (should (eq nil decknix--sidebar-show-progress))
      (decknix-sidebar-toggle-progress)
      (should (eq t   decknix--sidebar-show-progress)))))

(provide 'decknix-progress-sidebar-test)
;;; decknix-progress-sidebar-test.el ends here
