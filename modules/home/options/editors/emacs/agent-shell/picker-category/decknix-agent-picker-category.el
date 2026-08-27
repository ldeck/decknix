;;; decknix-agent-picker-category.el --- Category + attention sort for the buffer picker -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, picker

;;; Commentary:
;;
;; Pure helpers for the `C-c b' agent-buffer picker: classify a session
;; into Requests / WIP / Other so rows are distinguishable and filterable,
;; and rank sessions by how urgently they need attention so the picker can
;; surface those first.
;;
;;   `decknix--agent-picker-category-of'   TAGS  -> `requests'|`wip'|`other'
;;   `decknix--agent-picker-category-label' CAT  -> short display string
;;   `decknix--agent-picker-attention-rank' STATUS -> sort rank (low = urgent)
;;   `decknix--agent-picker-sort-key'      RANK MRU -> comparable order
;;
;; The classifier is a tag heuristic (no hub coupling): a `review' tag marks
;; a PR awaiting my review (Requests); a bare PR-number tag (`#N') without
;; `review' marks a PR I am working on (WIP); everything else is Other.
;;
;; Side-effect free; the picker wiring (reading buffer-local tags/status,
;; the filter state, the M-key toggles) lives in main-bulk / the heredoc
;; per AGENTS.md Rule 2.

;;; Code:

(require 'seq)
(require 'subr-x)

(defconst decknix--agent-picker-categories '(requests wip other)
  "Ordered category cycle for the picker's category filter.")

(defun decknix--agent-picker-category-of (tags)
  "Classify a session by its TAGS into `requests', `wip', or `other'.
`requests' when tagged \"review\" (a PR awaiting my review); `wip' when a
PR-number tag (\"#N\") is present without \"review\" (a PR I am working
on); `other' otherwise.  Pure heuristic over TAGS — no hub lookup."
  (cond
   ((member "review" tags) 'requests)
   ((seq-some (lambda (tg) (and (stringp tg)
                                (string-match-p "\\`#[0-9]+\\'" tg)))
              tags)
    'wip)
   (t 'other)))

(defun decknix--agent-picker-category-label (cat)
  "Return a short fixed-width display label for category CAT."
  (pcase cat
    ('requests "Req")
    ('wip      "WIP")
    (_         "Oth")))

(defun decknix--agent-picker-attention-rank (status)
  "Return a sort rank for STATUS; a lower rank needs attention sooner.
`netfail' (a turn killed by a dropped link, #162) is first: it is the
only status that will not move again on its own, and a link drop strands
several sessions at once.  Then `waiting' (a permission request blocking
the turn) and `asking' (a turn that ended by putting a question to you),
both stalled until you answer; then a finished turn awaiting me
\(`ready'/`finished'), then `closing', then an in-progress `working'
turn, then anything else (idle/killed/unknown)."
  (pcase status
    ("netfail"             -1)
    ((or "waiting" "asking") 0)
    ((or "ready" "finished") 1)
    ("closing"             2)
    ("working"             3)
    (_                     4)))

(defun decknix--agent-picker-order-index (buffers-with-keys)
  "Stable attention+MRU order for BUFFERS-WITH-KEYS.
Each element is (ITEM ATTENTION-RANK MRU-INDEX).  Returns the ITEMs sorted
by ATTENTION-RANK ascending, ties broken by MRU-INDEX ascending (so the
most-recently-used order is preserved within an attention band)."
  (mapcar #'car
          (sort (copy-sequence buffers-with-keys)
                (lambda (a b)
                  (if (= (nth 1 a) (nth 1 b))
                      (< (nth 2 a) (nth 2 b))
                    (< (nth 1 a) (nth 1 b)))))))

(provide 'decknix-agent-picker-category)
;;; decknix-agent-picker-category.el ends here
