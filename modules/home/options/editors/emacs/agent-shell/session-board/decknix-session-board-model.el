;;; decknix-session-board-model.el --- Session Board grouping -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, sessions, board

;;; Commentary:
;;
;; Pure model for the Session Board: every live session placed in exactly one
;; lane, so a fleet of them can be read and acted on in bulk.
;;
;; The board exists because the fleet outgrew per-session browsing.  Measured
;; on a live workspace: 36 sessions, of which 5 were running against PRs that
;; had named other individuals as reviewers and 16 against PRs that had left
;; both hub queries entirely.  Finding those took cross-referencing three data
;; sources by hand; the lanes are that cross-reference, done once.
;;
;; Lanes, in render order:
;;
;;   human-review  reviewing a human's PR -- the work that matters
;;   bot-review    reviewing a bot's PR (dependabot, augmentcode)
;;   wip           my own session, no review PR attached
;;   not-mine      reviewing a PR whose named reviewers do not include me
;;   orphaned      reviewing a PR absent from the feed: merged, closed, or no
;;                 longer requested of me
;;
;; `not-mine' and `orphaned' are last because they are the kill candidates:
;; everything above them is work, everything below is cleanup.
;;
;; Side-effecting render, marks and the quit action live in the board layer
;; per AGENTS.md Rule 2.

;;; Code:

(require 'seq)
(require 'subr-x)

(defconst decknix-session-board-lanes
  '(human-review bot-review wip not-mine orphaned)
  "Lanes in render order.")

(defconst decknix-session-board-lane-titles
  '((human-review . "Human Reviews")
    (bot-review   . "Bot Reviews")
    (wip          . "WIP")
    (not-mine     . "Not Mine")
    (orphaned     . "Orphaned"))
  "Human-readable lane titles.")

(defconst decknix-session-board-lane-hints
  '((human-review . "a colleague's PR")
    (bot-review   . "dependency bumps and bot PRs")
    (wip          . "my own sessions")
    (not-mine     . "named reviewers do not include me")
    (orphaned     . "PR merged, closed, or no longer requested"))
  "One-line explanation per lane, shown beside the count.

Carried here rather than in the render because a lane the user cannot
explain is a lane they will not trust enough to bulk-kill from.")

(defun decknix-session-board-lane-title (lane)
  "Return the display title for LANE."
  (or (alist-get lane decknix-session-board-lane-titles) (format "%s" lane)))

(defun decknix-session-board-lane-hint (lane)
  "Return the one-line hint for LANE."
  (or (alist-get lane decknix-session-board-lane-hints) ""))

;; --- classification ---------------------------------------------------

(defun decknix-session-board-classify (session item-for-key mine-p bot-p)
  "Return the lane for SESSION.

ITEM-FOR-KEY is a function from a PR key to its feed item (nil when the PR
is not in the feed).  MINE-P and BOT-P are predicates on a feed item.
Passed in rather than called directly so the whole classification stays
pure and testable without a hub.

A session with no review PR is mine -- `wip'.  Otherwise its FIRST review
PR decides: a grouped session covering several PRs of one repo is one piece
of work, and splitting it across lanes would offer to kill half of it."
  (let ((keys (decknix-session-board-session-prs session)))
    (if (null keys)
        'wip
      (let ((item (funcall item-for-key (car keys))))
        (cond
         ;; Absent from the feed: it has left both hub queries, so it is
         ;; merged, closed, or no longer requested of me.  Checked first
         ;; because every other test needs an item to look at.
         ((null item) 'orphaned)
         ((not (funcall mine-p item)) 'not-mine)
         ((funcall bot-p item) 'bot-review)
         (t 'human-review))))))

(defun decknix-session-board-session-prs (session)
  "Return SESSION's review-PR keys as recorded by the hub snapshot."
  (nth 2 session))

(defun decknix-session-board-row (session lane)
  "Return a board row plist for SESSION in LANE."
  (list :lane lane
        :buffer (nth 0 session)
        :tags (nth 1 session)
        :prs (decknix-session-board-session-prs session)
        :state (nth 3 session)
        :workspace (nth 4 session)
        :session session))

(defun decknix-session-board-row-key (row)
  "Return a stable identity for ROW.

The buffer name, which is what the quit action resolves and what survives a
re-render.  Marks are keyed on it, so a refresh between marking and killing
cannot shift a mark onto a different session."
  (plist-get row :buffer))

;; --- ordering ---------------------------------------------------------

(defconst decknix-session-board-state-order
  '("netfail" "waiting" "asking" "working" "finished" "ready" "closing")
  "Session states, most urgent first.
Same order the sidebar uses, so the two cannot disagree about urgency.")

(defun decknix-session-board-state-rank (state)
  "Return the urgency rank of STATE; lower is more urgent.
An unknown state sorts last: not recognising it is not evidence of
urgency."
  (or (seq-position decknix-session-board-state-order state)
      (length decknix-session-board-state-order)))

(defun decknix-session-board-sort-rows (rows)
  "Return ROWS urgency-first, then by buffer name."
  (sort (copy-sequence rows)
        (lambda (a b)
          (let ((ra (decknix-session-board-state-rank (plist-get a :state)))
                (rb (decknix-session-board-state-rank (plist-get b :state))))
            (if (/= ra rb)
                (< ra rb)
              (string< (or (plist-get a :buffer) "")
                       (or (plist-get b :buffer) "")))))))

(defun decknix-session-board-group (sessions item-for-key mine-p bot-p)
  "Return (LANE . ROWS) pairs for SESSIONS, in lane order.

Lanes with no sessions are omitted: an empty heading is a row of noise in a
board whose purpose is to show what is there."
  (let ((by-lane (make-hash-table :test 'eq)))
    (dolist (session sessions)
      (let ((lane (decknix-session-board-classify
                   session item-for-key mine-p bot-p)))
        (puthash lane
                 (cons (decknix-session-board-row session lane)
                       (gethash lane by-lane))
                 by-lane)))
    (delq nil
          (mapcar (lambda (lane)
                    (when-let ((rows (gethash lane by-lane)))
                      (cons lane (decknix-session-board-sort-rows rows))))
                  decknix-session-board-lanes))))

;; --- labels -----------------------------------------------------------

(defconst decknix-session-board-state-glyphs
  '(("asking" . "●") ("waiting" . "●") ("netfail" . "✖")
    ("working" . "◐") ("finished" . "◑") ("ready" . "○") ("closing" . "◌"))
  "Glyph per state.  A filled dot means the session wants you.")

(defun decknix-session-board-state-glyph (state)
  "Return the glyph for STATE."
  (or (alist-get state decknix-session-board-state-glyphs nil nil #'equal) "·"))

(defun decknix-session-board-short-name (buffer-name)
  "Return BUFFER-NAME without the agent wrapper."
  (replace-regexp-in-string
   "\\`\\*\\(Claude\\|Pi\\|Auggie\\|Codex\\|Gemini\\)?:? ?\\|\\*\\'" ""
   (or buffer-name "")))

(defun decknix-session-board-row-label (row marked-p width)
  "Return the rendered line for ROW, padded to WIDTH.

MARKED-P draws the leading mark.  The PR is shown rather than the buffer
name where one exists: for a review session the PR IS the identity, and the
buffer name is a naming convention that has changed twice."
  (let* ((state (plist-get row :state))
         (prs (plist-get row :prs))
         (name (if prs
                   (string-join prs ",")
                 (decknix-session-board-short-name (plist-get row :buffer))))
         (left (format "%s %s %s"
                       (if marked-p "*" " ")
                       (decknix-session-board-state-glyph state)
                       name))
         (right (or state ""))
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (concat left (make-string pad ?\s) right)))

(defun decknix-session-board-lane-header (lane rows width)
  "Return the heading line for LANE holding ROWS, padded to WIDTH."
  (let* ((left (format " %s (%d)" (decknix-session-board-lane-title lane)
                       (length rows)))
         (right (decknix-session-board-lane-hint lane))
         (pad (max 1 (- width (string-width left) (string-width right)))))
    (concat left (make-string pad ?\s) right)))

(defun decknix-session-board-summary (groups)
  "Return a one-line tally across GROUPS, or nil when there are none."
  (when groups
    (string-join
     (mapcar (lambda (g)
               (format "%d %s" (length (cdr g))
                       (decknix-session-board-lane-title (car g))))
             groups)
     " · ")))

(defun decknix-session-board-killable-lanes ()
  "Return the lanes whose sessions are cleanup rather than work."
  '(not-mine orphaned))

(defun decknix-session-board-killable-p (row)
  "Return non-nil when ROW is in a cleanup lane.

Used only to colour the row and to drive `kill all killable'; the kill
action itself works on any lane, because the user may well want to end a
real review too."
  (and (memq (plist-get row :lane) (decknix-session-board-killable-lanes)) t))

(provide 'decknix-session-board-model)
;;; decknix-session-board-model.el ends here
