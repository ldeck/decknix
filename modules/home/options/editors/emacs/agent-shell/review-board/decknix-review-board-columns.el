;;; decknix-review-board-columns.el --- Review board column cells -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review, board

;;; Commentary:
;;
;; The pure half of the board's row layout: what each column says for a
;; feed item, and how wide the flexible title column may be in a window
;; of a given width.  Every cell reads fields the hub already writes
;; (`author', `author_kind', `created', `updated', `ci.status',
;; `my_review', `human_unresolved', `bot_unresolved'), so a repaint asks
;; nothing of GitHub.

;;; Code:

(require 'map)
(require 'subr-x)

(defconst decknix-review-board-columns-bot-marker "⚙"
  "Suffix marking a bot author.")

(defconst decknix-review-board-columns-author-width 11
  "Width of the author column, marker included.")

(defun decknix-review-board-columns-author (author kind)
  "Return AUTHOR shortened for the author column.  Pure.
KIND is the feed's `author_kind'.  A bot loses its `[bot]' suffix and
`-bot' tail and gains `decknix-review-board-columns-bot-marker' instead,
so `dependabot[bot]' reads as `dependabot⚙' in eleven columns."
  (if (not (and (stringp author) (not (string-empty-p author))))
      ""
    (let* ((bot (or (member kind '("bot" "bot_human"))
                    (string-suffix-p "[bot]" author)))
           (name (replace-regexp-in-string "\\(\\[bot\\]\\|-bot\\)\\'" "" author))
           (room (- decknix-review-board-columns-author-width (if bot 1 0))))
      (concat (truncate-string-to-width name room)
              (if bot decknix-review-board-columns-bot-marker "")))))

(defun decknix-review-board-columns--parse-time (ts)
  "Return TS (an ISO 8601 string or a float time) as a float time, or nil."
  (cond ((numberp ts) (float ts))
        ((and (stringp ts) (not (string-empty-p ts)))
         (ignore-errors (float-time (date-to-time ts))))))

(defun decknix-review-board-columns-duration (secs)
  "Return SECS as a compact age: `now', `12m', `3h', `2d', `5w'.  Pure."
  (if (not (numberp secs))
      "-"
    (let ((s (max 0 (floor secs))))
      (cond ((< s 60) "now")
            ((< s 3600) (format "%dm" (/ s 60)))
            ((< s 86400) (format "%dh" (/ s 3600)))
            ((< s (* 14 86400)) (format "%dd" (/ s 86400)))
            (t (format "%dw" (/ s (* 7 86400))))))))

(defun decknix-review-board-columns-age (created last &optional now)
  "Return \"AGE/QUIET\": how old the PR is, and how long since anything moved.
CREATED is the PR's creation time and LAST its most recent activity
\(either an ISO string or a float time); NOW defaults to the current
time.  Either half reads `-' when unknown.  Pure."
  (let ((now (or now (float-time)))
        (c (decknix-review-board-columns--parse-time created))
        (l (decknix-review-board-columns--parse-time last)))
    (format "%s/%s"
            (decknix-review-board-columns-duration (and c (- now c)))
            (decknix-review-board-columns-duration (and l (- now l))))))

(defconst decknix-review-board-columns-ci-glyphs
  '(("pass" "✓" . 3) ("fail" "✗" . 0) ("running" "◐" . 2) ("pending" "◐" . 2))
  "CI status -> (GLYPH . SEVERITY-RANK), the sidebar's ranks.")

(defun decknix-review-board-columns-ci (item)
  "Return (GLYPH . RANK) for ITEM's CI status, or (\"·\" . 4).  Pure."
  (let ((status (map-elt (map-elt item 'ci) 'status)))
    (or (cdr (assoc status decknix-review-board-columns-ci-glyphs))
        (cons "·" 4))))

(defconst decknix-review-board-columns-review-labels
  '(("APPROVED" "A" . 3) ("CHANGES_REQUESTED" "CR" . 1)
    ("COMMENTED" "C" . 2) ("DISMISSED" "D" . 4))
  "My prior review state -> (LABEL . SEVERITY-RANK).")

(defun decknix-review-board-columns-my-review (item)
  "Return (LABEL . RANK) for my prior review of ITEM, or (\"\" . 4).  Pure."
  (or (cdr (assoc (map-elt item 'my_review)
                  decknix-review-board-columns-review-labels))
      (cons "" 4)))

(defun decknix-review-board-columns-threads (item)
  "Return ITEM's open threads as \"hN bN\": human, then bot.  Pure.
Empty when none is open.  Human first because a colleague's open
question is the one that wants reading; a bot thread is often noise."
  (let ((human (or (map-elt item 'human_unresolved) 0))
        (bot (or (map-elt item 'bot_unresolved) 0)))
    (string-join (delq nil (list (and (numberp human) (> human 0) (format "h%d" human))
                                 (and (numberp bot) (> bot 0) (format "b%d" bot))))
                 " ")))

(defconst decknix-review-board-columns-fixed-width 74
  "Columns a row uses outside the title and the phase text.
Mark, badge, glyph, priority, PR key, author, age, CI, my review and
threads, with their separators.")

(defconst decknix-review-board-columns-phase-width 30
  "Columns kept for the phase text after the fixed cells.")

(defun decknix-review-board-columns-title-width (window-width)
  "Return the title column's width for a window WINDOW-WIDTH wide.  Pure.
What is left after the fixed cells and the phase text, between 12 and 60.
The title gives way first: the PR key, the author and the phase are what
the row is read by."
  (max 12 (min 60 (- (or window-width 160)
                     decknix-review-board-columns-fixed-width
                     decknix-review-board-columns-phase-width))))

(defun decknix-review-board-columns-cell (text width)
  "Return TEXT truncated and padded to exactly WIDTH columns.  Pure."
  (truncate-string-to-width (or text "") width nil ?\s "…"))

(provide 'decknix-review-board-columns)
;;; decknix-review-board-columns.el ends here
