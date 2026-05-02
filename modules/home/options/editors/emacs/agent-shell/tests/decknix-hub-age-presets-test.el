;;; decknix-hub-age-presets-test.el --- Tests for hub age-filter presets -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-hub-age-presets "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the current behaviour of the hub age-filter
;; helpers extracted from the agent-shell heredoc.  Covers default
;; values, label lookup, cycle wrap, and the `decknix--hub-age-visible-p'
;; predicate's filter / parse-error / nil-iso branches.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-test-helpers)
(require 'decknix-hub-age-presets)

;; -- Defaults / preset table --------------------------------------

(ert-deftest decknix-hub-age-presets/filter-default-is-nil ()
  (let ((decknix--hub-age-filter nil))
    (should (null decknix--hub-age-filter))))

(ert-deftest decknix-hub-age-presets/preset-table-has-canonical-six-entries ()
  (should (equal '((nil    . "all")
                   (86400  . "1d")
                   (259200 . "3d")
                   (604800 . "7d")
                   (1209600 . "14d")
                   (2592000 . "30d"))
                 decknix--hub-age-presets)))

;; -- Label lookup -------------------------------------------------

(ert-deftest decknix-hub-age-presets/label-returns-all-when-filter-nil ()
  (let ((decknix--hub-age-filter nil))
    (should (equal "all" (decknix--hub-age-filter-label)))))

(ert-deftest decknix-hub-age-presets/label-returns-1d-when-filter-86400 ()
  (let ((decknix--hub-age-filter 86400))
    (should (equal "1d" (decknix--hub-age-filter-label)))))

(ert-deftest decknix-hub-age-presets/label-returns-30d-when-filter-2592000 ()
  (let ((decknix--hub-age-filter 2592000))
    (should (equal "30d" (decknix--hub-age-filter-label)))))

(ert-deftest decknix-hub-age-presets/label-falls-back-to-all-on-unknown-value ()
  (let ((decknix--hub-age-filter 99999999))
    (should (equal "all" (decknix--hub-age-filter-label)))))

;; -- Cycle wrap ---------------------------------------------------

(ert-deftest decknix-hub-age-presets/cycle-from-nil-advances-to-1d ()
  (let ((decknix--hub-age-filter nil))
    (decknix-test-with-stubbed-deps
        (agent-shell-workspace-sidebar-refresh)
      (decknix--hub-cycle-age-filter))
    (should (equal 86400 decknix--hub-age-filter))))

(ert-deftest decknix-hub-age-presets/cycle-from-30d-wraps-to-nil ()
  (let ((decknix--hub-age-filter 2592000))
    (decknix-test-with-stubbed-deps
        (agent-shell-workspace-sidebar-refresh)
      (decknix--hub-cycle-age-filter))
    (should (null decknix--hub-age-filter))))

(ert-deftest decknix-hub-age-presets/cycle-walks-full-six-step-loop ()
  (let ((decknix--hub-age-filter nil))
    (decknix-test-with-stubbed-deps
        (agent-shell-workspace-sidebar-refresh)
      (dotimes (_ 6) (decknix--hub-cycle-age-filter)))
    (should (null decknix--hub-age-filter))))

(ert-deftest decknix-hub-age-presets/cycle-refreshes-when-sidebar-buffer-exists ()
  (let ((decknix--hub-age-filter nil)
        (buf (generate-new-buffer "*agent-shell-sidebar*")))
    (unwind-protect
        (decknix-test-with-stubbed-deps
            (agent-shell-workspace-sidebar-refresh)
          (decknix--hub-cycle-age-filter)
          (should (= 1 (decknix-test-stub-call-count
                        'agent-shell-workspace-sidebar-refresh))))
      (kill-buffer buf))))

(ert-deftest decknix-hub-age-presets/cycle-skips-refresh-when-buffer-absent ()
  (let ((decknix--hub-age-filter nil))
    (when (get-buffer "*agent-shell-sidebar*")
      (kill-buffer "*agent-shell-sidebar*"))
    (decknix-test-with-stubbed-deps
        (agent-shell-workspace-sidebar-refresh)
      (decknix--hub-cycle-age-filter)
      (should (= 0 (decknix-test-stub-call-count
                    'agent-shell-workspace-sidebar-refresh))))))

;; -- Visibility predicate -----------------------------------------

(ert-deftest decknix-hub-age-presets/visible-p-returns-t-when-filter-nil ()
  (let ((decknix--hub-age-filter nil))
    (should (decknix--hub-age-visible-p nil))
    (should (decknix--hub-age-visible-p "2020-01-01T00:00:00Z"))
    (should (decknix--hub-age-visible-p "garbage"))))

(ert-deftest decknix-hub-age-presets/visible-p-returns-nil-when-filter-set-and-iso-nil ()
  (let ((decknix--hub-age-filter 86400))
    (should-not (decknix--hub-age-visible-p nil))))

(ert-deftest decknix-hub-age-presets/visible-p-returns-nil-when-filter-set-and-iso-non-string ()
  (let ((decknix--hub-age-filter 86400))
    (should-not (decknix--hub-age-visible-p 12345))))

(ert-deftest decknix-hub-age-presets/visible-p-returns-t-for-recent-iso-within-window ()
  (let ((decknix--hub-age-filter 86400)
        ;; 1 hour ago -> well within 1-day window.
        (recent (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                    (time-subtract (current-time) 3600)
                                    t)))
    (should (decknix--hub-age-visible-p recent))))

(ert-deftest decknix-hub-age-presets/visible-p-returns-nil-for-iso-outside-window ()
  (let ((decknix--hub-age-filter 86400)
        ;; 30 days ago -> outside 1-day window.
        (old (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                 (time-subtract (current-time) (* 30 86400))
                                 t)))
    (should-not (decknix--hub-age-visible-p old))))

(provide 'decknix-hub-age-presets-test)
;;; decknix-hub-age-presets-test.el ends here
