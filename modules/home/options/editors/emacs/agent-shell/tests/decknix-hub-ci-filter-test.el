;;; decknix-hub-ci-filter-test.el --- Tests for hub CI status filter -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-ci-filter "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the CI filter module extracted
;; from the hub heredoc.  Covers the default visible-set, the
;; canonical render-order alist, single-bucket toggling, the
;; propertised footer summary, the predicate that drives sidebar
;; row visibility, and the bulk show-all / show-none verbs.
;;
;; The sidebar redraw side-effect inside `decknix--hub-ci-filter-refresh'
;; is gated on `(get-buffer agent-shell-workspace-sidebar-buffer-name)'
;; (the upstream buffer name is "*Agent Sidebar*") which is nil in
;; ert-batch, so tests that call the per-bucket toggles do not need
;; to stub `agent-shell-workspace-sidebar-refresh'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-ci-filter)

(defmacro decknix-hub-ci-filter-test--with-state (state &rest body)
  "Evaluate BODY with `decknix--hub-ci-filter' bound to STATE.
Bindings are dynamic so the byte-compiled module sees the test's
filter list when it accesses the global."
  (declare (indent 1))
  `(let ((decknix--hub-ci-filter ,state))
     ,@body))

;; -- defaults ------------------------------------------------------

(ert-deftest decknix-hub-ci-filter--defaults ()
  "All five status buckets are visible at module load."
  (should (member "pass"      decknix--hub-ci-filter))
  (should (member "fail"      decknix--hub-ci-filter))
  (should (member "soft_fail" decknix--hub-ci-filter))
  (should (member "running"   decknix--hub-ci-filter))
  (should (member "unknown"   decknix--hub-ci-filter))
  (should (= 5 (length decknix--hub-ci-filter))))

(ert-deftest decknix-hub-ci-filter--order-shape ()
  "Render-order carries five rows, each (STATUS ICON FACE)."
  (should (= 5 (length decknix--hub-ci-filter-order)))
  (dolist (row decknix--hub-ci-filter-order)
    (should (= 3 (length row)))
    (should (stringp (nth 0 row)))
    (should (stringp (nth 1 row)))
    (should (symbolp (nth 2 row))))
  ;; Order matches the documented contract:
  ;; pass, soft_fail, fail, running, unknown.
  (should (equal '("pass" "soft_fail" "fail" "running" "unknown")
                 (mapcar #'car decknix--hub-ci-filter-order))))

;; -- visible-p predicate -------------------------------------------

(ert-deftest decknix-hub-ci-filter--visible-p-passes ()
  "All-visible default => every status passes the predicate."
  (cl-letf (((symbol-function 'decknix--hub-ci-classify)
             (lambda (_ci) "pass")))
    (should (decknix--hub-ci-visible-p '((ci . anything))))))

(ert-deftest decknix-hub-ci-filter--visible-p-rejects-when-removed ()
  "Removing a status from the filter rejects items of that status."
  (decknix-hub-ci-filter-test--with-state '("pass" "running")
    (cl-letf (((symbol-function 'decknix--hub-ci-classify)
               (lambda (_ci) "fail")))
      (should-not (decknix--hub-ci-visible-p '((ci . anything))))
      ;; Sanity: a passing item still shows.
      (cl-letf (((symbol-function 'decknix--hub-ci-classify)
                 (lambda (_ci) "pass")))
        (should (decknix--hub-ci-visible-p '((ci . anything))))))))

;; -- summary string ------------------------------------------------

(ert-deftest decknix-hub-ci-filter--summary-icon-coverage ()
  "Summary contains every canonical icon and is propertised per-icon.
Strict equal-length check against the order alist makes sure no
icon is silently dropped or duplicated in a future refactor."
  (let* ((summary (decknix--hub-ci-filter-summary))
         (icons (mapcar (lambda (e) (nth 1 e))
                        decknix--hub-ci-filter-order)))
    (dolist (icon icons)
      (should (string-match-p (regexp-quote icon) summary)))
    (should (= (length summary) (length icons)))))

(ert-deftest decknix-hub-ci-filter--summary-shadows-disabled ()
  "Summary applies `shadow' face to icons whose status is filtered out.
Every icon has a face property; disabled buckets carry shadow,
enabled buckets carry their status-specific face from the order
alist."
  (decknix-hub-ci-filter-test--with-state '("pass")
    (let ((summary (decknix--hub-ci-filter-summary)))
      ;; The "pass" icon is the first entry.
      (should (eq 'success (get-text-property 0 'face summary)))
      ;; Every other icon should be shadowed.
      (cl-loop for i from 1 below (length summary) do
               (should (eq 'shadow (get-text-property i 'face summary)))))))

;; -- toggle reciprocity --------------------------------------------

(ert-deftest decknix-hub-ci-filter--toggle-status-removes-then-adds ()
  "Toggling a present status removes it; toggling again restores."
  (decknix-hub-ci-filter-test--with-state
      '("pass" "fail" "soft_fail" "running" "unknown")
    (decknix--hub-ci-toggle-status "fail")
    (should-not (member "fail" decknix--hub-ci-filter))
    (decknix--hub-ci-toggle-status "fail")
    (should (member "fail" decknix--hub-ci-filter))))

;; -- show-all / show-none semantics --------------------------------

(ert-deftest decknix-hub-ci-filter--show-none-empties-set ()
  "`show-none' empties the visible set entirely."
  (decknix-hub-ci-filter-test--with-state
      '("pass" "fail" "soft_fail" "running" "unknown")
    (decknix--hub-ci-filter-show-none)
    (should (null decknix--hub-ci-filter))))

(ert-deftest decknix-hub-ci-filter--show-all-restores-canonical ()
  "`show-all' restores the canonical 5-bucket set, even from empty."
  (decknix-hub-ci-filter-test--with-state nil
    (decknix--hub-ci-filter-show-all)
    (should (= 5 (length decknix--hub-ci-filter)))
    (dolist (s '("pass" "fail" "soft_fail" "running" "unknown"))
      (should (member s decknix--hub-ci-filter)))))

;; -- transient row description -------------------------------------

(ert-deftest decknix-hub-ci-filter--status-desc-shape ()
  "Row description embeds the icon, the label, and the [x]/[ ] toggle.
Enabled icons carry the status-specific face; disabled icons dim."
  (decknix-hub-ci-filter-test--with-state '("pass")
    (let ((on-row  (decknix--hub-ci-filter-status-desc
                    "pass" "✓" "green   (pass)"))
          (off-row (decknix--hub-ci-filter-status-desc
                    "fail" "✗" "red     (hard-fail)")))
      (should (string-match-p "\\[x\\]" on-row))
      (should (string-match-p "✓" on-row))
      (should (string-match-p "green   (pass)" on-row))
      (should (string-match-p "\\[ \\]" off-row))
      (should (string-match-p "✗" off-row))
      (should (string-match-p "red     (hard-fail)" off-row)))))

(provide 'decknix-hub-ci-filter-test)
;;; decknix-hub-ci-filter-test.el ends here
