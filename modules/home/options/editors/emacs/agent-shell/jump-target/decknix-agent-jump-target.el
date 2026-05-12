;;; decknix-agent-jump-target.el --- JumpTarget strategy resolver -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, search, jump

;;; Commentary:
;;
;; JumpTarget strategy resolver for the SessionSearch bounded
;; context (PR B.77).  Carved from
;; `decknix--agent-session-jump-to-match' (#136 cross-window jump):
;; the *decision* about where to land for a search term is
;; separated from the *side-effects* of buffer search, window
;; mutation, and section-render expansion -- which remain in
;; main-bulk per AGENTS.md Rule 2.
;;
;; Two pure helpers:
;;
;;   `decknix--jump-target-anchor-for-window-bottom'
;;     Domain rule: place IDX as the last (newest) turn in a
;;     COUNT-sized window, clamped at zero so the anchor stays a
;;     valid history offset.
;;
;;   `decknix--jump-target-resolve'
;;     Strategy resolver: given the results of two searches
;;     (BUFFER-HIT and CACHE-IDX), return a plist describing what
;;     the caller should do next.
;;
;; The strategy values:
;;
;;   (:strategy in-buffer      :hit POS)
;;     -- term is already visible in the rendered buffer; caller
;;        moves window-point to POS and recenters.
;;
;;   (:strategy render-window  :anchor N)
;;     -- term lives in `decknix--agent-history-cache' but lies
;;        outside the currently-rendered window; caller re-renders
;;        anchored at N (so the matched turn lands at the bottom),
;;        force-expands the section, and re-runs its buffer
;;        search.  If that re-search misses (truncation edge),
;;        caller falls back to point-max with a "truncated out of
;;        view" message.
;;
;;   (:strategy not-found)
;;     -- term is in neither the buffer nor the cache; caller
;;        moves window-point to point-max and shows the
;;        "not in loaded history" message.
;;
;; Buffer-hit precedence: when BOTH searches succeed, BUFFER-HIT
;; wins.  This preserves the original #136 behaviour: the
;; rendered match is closer to the user's gaze than any cache
;; hit, and re-rendering would be wasted work.
;;
;; Single-responsibility (SOLID): this module knows the decision
;; tree and the anchor formula -- nothing about windows, point,
;; rendering, or `decknix--agent-history-cache' itself.  Bulk owns
;; cache lookup (`decknix--agent-session-find-turn-containing'),
;; the `find-in-buffer' helper, the `land-on' window mutator, and
;; the `decknix--agent-context-render-window' / force-expand
;; orchestration.

;;; Code:

(defun decknix--jump-target-anchor-for-window-bottom (idx count)
  "Return the anchor that places IDX as the last turn in a COUNT-sized window.

Anchor is the index of the *first* turn shown.  Clamped at zero
so an early-history match (IDX < COUNT) anchors at the start of
history rather than producing a negative offset."
  (max 0 (- (1+ idx) count)))

(defun decknix--jump-target-resolve (buffer-hit cache-idx count)
  "Resolve the jump strategy for a search.

BUFFER-HIT is the position returned by an earlier in-buffer
`search-forward' (or nil if the term is not visible).  CACHE-IDX
is the turn-index returned by an earlier
`decknix--agent-session-find-turn-containing' against
`decknix--agent-history-cache' (or nil).  COUNT is the
window-size budget (`decknix-agent-session-history-count').

Returns a plist describing the next action; see file commentary
for the three strategy variants and their semantics.  BUFFER-HIT
wins when both inputs are non-nil so an already-visible match is
not re-rendered."
  (cond
   (buffer-hit
    (list :strategy 'in-buffer :hit buffer-hit))
   (cache-idx
    (list :strategy 'render-window
          :anchor (decknix--jump-target-anchor-for-window-bottom
                   cache-idx count)))
   (t
    (list :strategy 'not-found))))

(provide 'decknix-agent-jump-target)
;;; decknix-agent-jump-target.el ends here
