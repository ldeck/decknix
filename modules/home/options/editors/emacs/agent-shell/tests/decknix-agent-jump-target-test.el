;;; decknix-agent-jump-target-test.el --- Tests for jump-target resolver -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-jump-target' (PR B.77).
;; Exercises the two pure helpers carved from
;; `decknix--agent-session-jump-to-match' (#136 cross-window jump):
;;
;;   `decknix--jump-target-anchor-for-window-bottom' -- anchor
;;     formula that places the matched turn as the last (newest)
;;     turn in a window of COUNT turns, clamped at zero.
;;
;;   `decknix--jump-target-resolve' -- Strategy resolver returning
;;     `(:strategy in-buffer :hit POS)' | `(:strategy render-window
;;     :anchor N)' | `(:strategy not-found)'.
;;
;; No buffer state, no rendering, no window mutation: all
;; side-effects stay in the bulk dispatcher per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-agent-jump-target)

;; --- anchor-for-window-bottom ---

(ert-deftest decknix-jump-target--anchor-mid-history ()
  "IDX comfortably inside history: anchor lands COUNT-1 turns before IDX."
  (should (= 6 (decknix--jump-target-anchor-for-window-bottom 10 5))))

(ert-deftest decknix-jump-target--anchor-clamps-to-zero ()
  "When IDX < COUNT, anchor would go negative; clamped at 0."
  (should (= 0 (decknix--jump-target-anchor-for-window-bottom 2 5))))

(ert-deftest decknix-jump-target--anchor-first-turn ()
  "IDX = 0 is always anchored at 0 regardless of COUNT."
  (should (= 0 (decknix--jump-target-anchor-for-window-bottom 0 5))))

(ert-deftest decknix-jump-target--anchor-exactly-window-size ()
  "IDX = COUNT-1 anchors at 0 (the full first window contains IDX)."
  (should (= 0 (decknix--jump-target-anchor-for-window-bottom 4 5))))

(ert-deftest decknix-jump-target--anchor-window-of-one ()
  "Window of 1: anchor always equals IDX (matched turn is the only turn)."
  (should (= 7 (decknix--jump-target-anchor-for-window-bottom 7 1)))
  (should (= 0 (decknix--jump-target-anchor-for-window-bottom 0 1))))

;; --- resolve (Strategy pattern) ---

(ert-deftest decknix-jump-target--resolve-in-buffer-when-buffer-hit ()
  "BUFFER-HIT non-nil short-circuits to `in-buffer'."
  (should (equal '(:strategy in-buffer :hit 42)
                 (decknix--jump-target-resolve 42 nil 5))))

(ert-deftest decknix-jump-target--resolve-buffer-wins-over-cache ()
  "When both BUFFER-HIT and CACHE-IDX are present, buffer wins (#136)."
  (should (equal '(:strategy in-buffer :hit 42)
                 (decknix--jump-target-resolve 42 10 5))))

(ert-deftest decknix-jump-target--resolve-render-window-when-cache-hit ()
  "BUFFER-HIT nil + CACHE-IDX non-nil -> render-window with anchor."
  (should (equal '(:strategy render-window :anchor 6)
                 (decknix--jump-target-resolve nil 10 5))))

(ert-deftest decknix-jump-target--resolve-render-window-clamps-anchor ()
  "Render-window strategy uses the same clamped-at-zero formula."
  (should (equal '(:strategy render-window :anchor 0)
                 (decknix--jump-target-resolve nil 2 5))))

(ert-deftest decknix-jump-target--resolve-not-found ()
  "Both inputs nil -> `not-found'."
  (should (equal '(:strategy not-found)
                 (decknix--jump-target-resolve nil nil 5))))

(provide 'decknix-agent-jump-target-test)
;;; decknix-agent-jump-target-test.el ends here
