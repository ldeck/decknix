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
;;   `decknix--agent-picker-order-index'   ROWS -> stable rank/MRU order
;;   `decknix--agent-picker-order'         ROWS -> needs-you first, then the rest
;;   `decknix--agent-picker-state-prefix'  STATE -> the sidebar's glyph, in its face
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
(require 'decknix-attention)
(require 'decknix-sidebar-layout)

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
Every state that `decknix-attention' says needs you shares the top band;
`decknix--agent-picker-order' ranks within it.  Then a finished turn
awaiting me (`ready'/`finished'), then `closing', then an in-progress
`working' turn, then anything else (idle/killed/unknown)."
  (cond
   ((decknix-attention-state-p status) 0)
   ((member status '("ready" "finished")) 1)
   ((equal status "closing") 2)
   ((equal status "working") 3)
   (t 4)))

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

(defun decknix--agent-picker-order (rows &optional order-fn)
  "Return the ITEMs of ROWS, sessions needing you first.

Each row is (ITEM NAME STATE MRU-INDEX).  The sessions needing you come
in the order ORDER-FN gives their (NAME nil nil STATE ITEM) tuples,
default `decknix-attention-order'; the picker passes
`decknix-attention-ordered-sessions', which is the order the sidebar's
Needs-you block and the jump use.  The rest follow by
`decknix--agent-picker-attention-rank', MRU within a band."
  (let* ((needs (seq-filter (lambda (r) (decknix-attention-state-p (nth 2 r))) rows))
         (rest (seq-remove (lambda (r) (decknix-attention-state-p (nth 2 r))) rows))
         (tuples (mapcar (lambda (r) (list (nth 1 r) nil nil (nth 2 r) (nth 0 r)))
                         needs)))
    (append
     (mapcar (lambda (tu) (nth 4 tu))
             (funcall (or order-fn #'decknix-attention-order) tuples))
     (decknix--agent-picker-order-index
      (mapcar (lambda (r)
                (list (nth 0 r) (decknix--agent-picker-attention-rank (nth 2 r))
                      (nth 3 r)))
              rest)))))

(defun decknix--agent-picker-state-prefix (state)
  "Return STATE's sidebar glyph in the sidebar's face, plus a space."
  (concat (propertize (decknix--layout-state-glyph state)
                      'face (decknix--layout-state-face state))
          " "))

(provide 'decknix-agent-picker-category)
;;; decknix-agent-picker-category.el ends here
