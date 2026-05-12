;;; decknix-agent-quickaction-window-test.el --- Tests for quickaction window resolver -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-quickaction-window'
;; (PR B.80).

;;; Code:

(require 'ert)
(require 'decknix-agent-quickaction-window)

;; --- is-sidebar-p ---

(ert-deftest decknix-quickaction-window--side-param-detects ()
  "Any non-nil `window-side' parameter classifies the window as a sidebar."
  (should (decknix--quickaction-window-is-sidebar-p
           'left nil "*scratch*" "*agent-shell-sidebar*"))
  (should (decknix--quickaction-window-is-sidebar-p
           'right nil "*scratch*" "*agent-shell-sidebar*")))

(ert-deftest decknix-quickaction-window--dedicated-detects ()
  "A dedicated window classifies as sidebar even without a side parameter."
  (should (decknix--quickaction-window-is-sidebar-p
           nil t "*scratch*" "*agent-shell-sidebar*")))

(ert-deftest decknix-quickaction-window--buffer-name-detects ()
  "Window whose buffer matches SIDEBAR-NAME classifies as sidebar."
  (should (decknix--quickaction-window-is-sidebar-p
           nil nil "*agent-shell-sidebar*" "*agent-shell-sidebar*")))

(ert-deftest decknix-quickaction-window--non-sidebar-rejected ()
  "Plain window with mismatched buffer name returns nil."
  (should-not (decknix--quickaction-window-is-sidebar-p
               nil nil "*scratch*" "*agent-shell-sidebar*")))

(ert-deftest decknix-quickaction-window--nil-buffer-names-tolerated ()
  "Nil buffer / sidebar name does not crash; predicate falls back to nil."
  (should-not (decknix--quickaction-window-is-sidebar-p
               nil nil nil "*agent-shell-sidebar*"))
  (should-not (decknix--quickaction-window-is-sidebar-p
               nil nil "*scratch*" nil))
  (should-not (decknix--quickaction-window-is-sidebar-p
               nil nil nil nil)))

(ert-deftest decknix-quickaction-window--all-signals-positive ()
  "When every signal fires the predicate is still just non-nil."
  (should (decknix--quickaction-window-is-sidebar-p
           'left t "*agent-shell-sidebar*" "*agent-shell-sidebar*")))

;; --- target-window ---

(ert-deftest decknix-quickaction-window--target-non-sidebar-returns-cur ()
  "Non-sidebar caller: new session replaces caller window in place."
  (should (eq 'cur-win
              (decknix--quickaction-target-window nil 'cur-win 'main-win))))

(ert-deftest decknix-quickaction-window--target-sidebar-prefers-main ()
  "Sidebar caller: new session lands in the frame's main window."
  (should (eq 'main-win
              (decknix--quickaction-target-window t 'cur-win 'main-win))))

(ert-deftest decknix-quickaction-window--target-sidebar-falls-back-to-cur ()
  "Sidebar caller with nil MAIN-WIN: fall back to CUR (last-resort)."
  (should (eq 'cur-win
              (decknix--quickaction-target-window t 'cur-win nil))))

(ert-deftest decknix-quickaction-window--target-non-sidebar-ignores-main ()
  "Non-sidebar caller never picks MAIN-WIN even when it's available."
  (should (eq 'cur-win
              (decknix--quickaction-target-window nil 'cur-win 'main-win))))

(provide 'decknix-agent-quickaction-window-test)
;;; decknix-agent-quickaction-window-test.el ends here
