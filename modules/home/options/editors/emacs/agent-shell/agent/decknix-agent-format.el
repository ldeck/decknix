;;; decknix-agent-format.el --- Agent display formatters -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, time, format

;;; Commentary:
;;
;; Pure display-formatting primitives extracted from the agent-shell
;; heredoc.
;;
;; Time formatters — both take an ISO-8601 timestamp string and
;; return a human-readable relative-time string with the same
;; bucket boundaries (1m / 1h / 1d / 30d):
;;
;;   `decknix--agent-session-time-ago'      ("just now" / "Nm ago" /
;;                                           "Nh ago" / "Nd ago" /
;;                                           "YYYY-MM-DD")
;;   `decknix--agent-session-time-compact'  ("now" / "Nm" / "Nh" /
;;                                           "Nd" / "MM/DD")
;;
;; Both functions read `(current-time)' for the delta computation;
;; tests stub it via `cl-letf' for deterministic boundary checks.
;;
;; String formatters:
;;
;;   `decknix--prompt-truncate-for-display' (prompt + max-len ->
;;                                           single-line truncated
;;                                           string with newlines
;;                                           collapsed to ↵; appends
;;                                           an ellipsis on overflow)

;;; Code:

(defun decknix--agent-session-time-ago (iso-time)
  "Format ISO-TIME as a relative time string (e.g. \"2h ago\")."
  (let* ((time (date-to-time iso-time))
         (delta (float-time (time-subtract (current-time) time)))
         (minutes (/ delta 60))
         (hours (/ delta 3600))
         (days (/ delta 86400)))
    (cond ((< minutes 1) "just now")
          ((< minutes 60) (format "%dm ago" (truncate minutes)))
          ((< hours 24) (format "%dh ago" (truncate hours)))
          ((< days 30) (format "%dd ago" (truncate days)))
          (t (format-time-string "%Y-%m-%d" time)))))

(defun decknix--agent-session-time-compact (iso-time)
  "Format ISO-TIME as a compact relative time (e.g. \"2h\", \"5d\").
Used in the sidebar where horizontal space is at a premium."
  (let* ((time (date-to-time iso-time))
         (delta (float-time (time-subtract (current-time) time)))
         (minutes (/ delta 60))
         (hours (/ delta 3600))
         (days (/ delta 86400)))
    (cond ((< minutes 1) "now")
          ((< minutes 60) (format "%dm" (truncate minutes)))
          ((< hours 24) (format "%dh" (truncate hours)))
          ((< days 30) (format "%dd" (truncate days)))
          (t (format-time-string "%m/%d" time)))))

(defun decknix--prompt-truncate-for-display (prompt max-len)
  "Truncate PROMPT to MAX-LEN chars, collapsing newlines to ↵."
  (let* ((collapsed (replace-regexp-in-string "[\n\r]+" " ↵ " prompt))
         (trimmed (string-trim collapsed)))
    (if (<= (length trimmed) max-len)
        trimmed
      (concat (substring trimmed 0 (- max-len 1)) "…"))))

(provide 'decknix-agent-format)
;;; decknix-agent-format.el ends here
