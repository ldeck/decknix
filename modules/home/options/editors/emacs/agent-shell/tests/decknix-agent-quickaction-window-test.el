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

;; --- quit-pick-replacement ---

(ert-deftest decknix-quickaction-window--quit-empty-mru-returns-nil ()
  "No remaining live sessions: caller routes to welcome / scratch."
  (should (null (decknix--quit-pick-replacement nil nil)))
  (should (null (decknix--quit-pick-replacement nil '(visible-a)))))

(ert-deftest decknix-quickaction-window--quit-single-mru-returned ()
  "Only one remaining session: it is returned even if visible elsewhere
\(forced reuse — there is no other choice)."
  (should (eq 'a (decknix--quit-pick-replacement '(a) nil)))
  (should (eq 'a (decknix--quit-pick-replacement '(a) '(a)))))

(ert-deftest decknix-quickaction-window--quit-prefers-hidden-mru ()
  "When MRU head is visible elsewhere, pick the next hidden candidate."
  (should (eq 'b
              (decknix--quit-pick-replacement '(a b c) '(a))))
  (should (eq 'c
              (decknix--quit-pick-replacement '(a b c) '(a b)))))

(ert-deftest decknix-quickaction-window--quit-no-overlap-returns-head ()
  "When no MRU candidate is visible elsewhere, return the MRU head."
  (should (eq 'a
              (decknix--quit-pick-replacement '(a b c) nil)))
  (should (eq 'a
              (decknix--quit-pick-replacement '(a b c) '(x y)))))

(ert-deftest decknix-quickaction-window--quit-all-visible-falls-back ()
  "When every MRU candidate is on screen, fall back to MRU head."
  (should (eq 'a
              (decknix--quit-pick-replacement '(a b) '(a b)))))

;; --- quickaction-window-candidates ---

(ert-deftest decknix-quickaction-window--candidates-empty-returns-nil ()
  "Empty descriptor list: nil (caller skips prompt)."
  (should (null (decknix--quickaction-window-candidates nil))))

(ert-deftest decknix-quickaction-window--candidates-single-pane-returns-nil ()
  "Single non-sidebar pane: nil (no choice to offer)."
  (should (null (decknix--quickaction-window-candidates
                 '((win-a "*foo*" t nil))))))

(ert-deftest decknix-quickaction-window--candidates-two-panes-returns-nil ()
  "Two non-sidebar panes: still nil — threshold is >=3 (current pane
just gets replaced via the existing fast-path)."
  (should (null (decknix--quickaction-window-candidates
                 '((win-a "*foo*" t nil)
                   (win-b "*bar*" nil nil))))))

(ert-deftest decknix-quickaction-window--candidates-sidebar-not-counted ()
  "Sidebar descriptors do not contribute to the threshold."
  (should (null (decknix--quickaction-window-candidates
                 '((win-side "*agent-shell-sidebar*" nil t)
                   (win-a "*foo*" t nil)
                   (win-b "*bar*" nil nil))))))

(ert-deftest decknix-quickaction-window--candidates-three-panes-nine-cands ()
  "Three non-sidebar panes: nine candidates (3 replace + 3 split-right + 3 split-below)."
  (let ((cands (decknix--quickaction-window-candidates
                '((win-a "*foo*" t nil)
                  (win-b "*bar*" nil nil)
                  (win-c "*baz*" nil nil)))))
    (should (= 9 (length cands)))
    ;; First three entries are Replace; next three Split right;
    ;; final three Split below.
    (should (eq :replace (nth 1 (nth 0 cands))))
    (should (eq :replace (nth 1 (nth 1 cands))))
    (should (eq :replace (nth 1 (nth 2 cands))))
    (should (eq :split-right (nth 1 (nth 3 cands))))
    (should (eq :split-right (nth 1 (nth 4 cands))))
    (should (eq :split-right (nth 1 (nth 5 cands))))
    (should (eq :split-below (nth 1 (nth 6 cands))))
    (should (eq :split-below (nth 1 (nth 7 cands))))
    (should (eq :split-below (nth 1 (nth 8 cands))))))

(ert-deftest decknix-quickaction-window--candidates-current-listed-first ()
  "Current window leads each variant group so RET = today's behaviour."
  (let ((cands (decknix--quickaction-window-candidates
                '((win-a "*foo*" nil nil)
                  (win-b "*bar*" t nil)
                  (win-c "*baz*" nil nil)))))
    ;; Within Replace group (first three), current window's anchor
    ;; should appear first.
    (should (eq 'win-b (nth 2 (nth 0 cands))))
    ;; And again for the Split right / Split below groups.
    (should (eq 'win-b (nth 2 (nth 3 cands))))
    (should (eq 'win-b (nth 2 (nth 6 cands))))))

(ert-deftest decknix-quickaction-window--candidates-sidebar-filtered ()
  "Sidebar descriptors do not appear in the candidate list."
  (let* ((cands (decknix--quickaction-window-candidates
                 '((win-side "*agent-shell-sidebar*" nil t)
                   (win-a "*foo*" t nil)
                   (win-b "*bar*" nil nil)
                   (win-c "*baz*" nil nil))))
         (anchors (mapcar (lambda (e) (nth 2 e)) cands)))
    (should (= 9 (length cands)))
    (should-not (memq 'win-side anchors))))

(ert-deftest decknix-quickaction-window--candidates-labels-include-buffer-name ()
  "Each label embeds the anchor window's buffer name for discoverability."
  (let ((cands (decknix--quickaction-window-candidates
                '((win-a "*foo*" t nil)
                  (win-b "*bar*" nil nil)
                  (win-c "*baz*" nil nil)))))
    (should (string-match-p "foo" (nth 0 (nth 0 cands))))
    (should (string-match-p "Replace" (nth 0 (nth 0 cands))))
    (should (string-match-p "Split right" (nth 0 (nth 3 cands))))
    (should (string-match-p "Split below" (nth 0 (nth 6 cands))))))

(provide 'decknix-agent-quickaction-window-test)
;;; decknix-agent-quickaction-window-test.el ends here
