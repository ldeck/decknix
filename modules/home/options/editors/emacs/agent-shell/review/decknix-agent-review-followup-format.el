;;; decknix-agent-review-followup-format.el --- Follow-up id + describe formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, review, followup, format

;;; Commentary:
;;
;; Two carved helpers that back the `decknix-agent-review-mode'
;; follow-up stash extracted from the agent-shell heredoc:
;;
;;   `decknix--agent-review-followup-id'
;;       Generates a short, time-ordered id of the form
;;       `fu-YYYYMMDDHHMMSS-XXXX' where XXXX is a 4-hex-digit
;;       random suffix.  Reads `current-time' + `random' so it is
;;       not pure in the strict sense, but carries no other state
;;       and matches the carving pattern already established by
;;       `decknix-agent-session-id'.
;;
;;   `decknix--agent-review-followup-describe'
;;       Single-line label formatter for a follow-up alist ENTRY
;;       used as the candidate string in the
;;       `decknix-agent-review-list-followups' completing-read.
;;       Renders id, status (faced — comment for `done', warning
;;       otherwise), parsed date from `ts', and title.  Defaults
;;       cover missing fields: id -> "?", status -> "open", title
;;       -> "(untitled)", invalid ts -> falls back to current
;;       epoch via `ignore-errors' around `date-to-time'.
;;
;; Both helpers live together because they are the two pure /
;; near-pure pieces of the follow-up render pipeline; the I/O
;; counterparts (`-followups-read', `-followups-write',
;; `-followup-set-status', `-followup-delete') stay in main-bulk
;; alongside the user-tunable file path defvar.

;;; Code:

(defun decknix--agent-review-followup-id ()
  "Generate a short, time-ordered id for a follow-up.
The shape is `fu-YYYYMMDDHHMMSS-XXXX' where XXXX is a 4-hex-digit
random suffix.  Sortable lexicographically by creation time."
  (format "fu-%s-%04x"
          (format-time-string "%Y%m%d%H%M%S")
          (random 65536)))

(defun decknix--agent-review-followup-describe (entry)
  "Return a single-line label for follow-up ENTRY.
ENTRY is an alist with keys `id', `status', `ts', `title'.  Used
as the completing-read candidate string in
`decknix-agent-review-list-followups'."
  (format "%s  %-7s  %s  %s"
          (or (alist-get 'id entry) "?")
          (propertize (or (alist-get 'status entry) "open")
                      'face (if (string= (alist-get 'status entry) "done")
                                'font-lock-comment-face
                              'font-lock-warning-face))
          (format-time-string "%Y-%m-%d"
                              (ignore-errors
                                (date-to-time
                                 (alist-get 'ts entry ""))))
          (or (alist-get 'title entry) "(untitled)")))

(provide 'decknix-agent-review-followup-format)
;;; decknix-agent-review-followup-format.el ends here
