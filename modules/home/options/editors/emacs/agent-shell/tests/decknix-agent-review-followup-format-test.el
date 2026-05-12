;;; decknix-agent-review-followup-format-test.el --- Tests for follow-up id + describe -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-review-followup-format "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning current behaviour of the carved follow-up
;; id generator and describe formatter.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-review-followup-format)

;; -- followup-id ---------------------------------------------------

(ert-deftest decknix-agent-review-followup-id--shape ()
  "Id matches `fu-<14 digits>-<4 hex>'."
  (let ((id (decknix--agent-review-followup-id)))
    (should (string-match-p
             "\\`fu-[0-9]\\{14\\}-[0-9a-f]\\{4\\}\\'"
             id))))

(ert-deftest decknix-agent-review-followup-id--prefix ()
  "Id always starts with the `fu-' literal."
  (should (string-prefix-p "fu-" (decknix--agent-review-followup-id))))

(ert-deftest decknix-agent-review-followup-id--time-ordered ()
  "Two ids generated 1.05 s apart sort lexicographically by creation
time (the YYYYMMDDHHMMSS prefix dominates the random suffix)."
  (let* ((a (decknix--agent-review-followup-id))
         (_ (sleep-for 1.05))
         (b (decknix--agent-review-followup-id)))
    (should (string-lessp a b))))

;; -- followup-describe ---------------------------------------------

(ert-deftest decknix-agent-review-followup-describe--full-entry ()
  "Full entry renders id, status, formatted date, title in order."
  (let* ((entry '((id . "fu-20251101120000-abcd")
                  (status . "open")
                  (ts . "2025-11-01T12:00:00+0000")
                  (title . "Follow up on auth")))
         (label (decknix--agent-review-followup-describe entry)))
    (should (string-match-p "fu-20251101120000-abcd" label))
    (should (string-match-p "open" label))
    (should (string-match-p "2025-11-01" label))
    (should (string-match-p "Follow up on auth" label))))

(ert-deftest decknix-agent-review-followup-describe--missing-id ()
  "Missing id renders the `?' placeholder."
  (let ((label (decknix--agent-review-followup-describe
                '((status . "open")
                  (ts . "2025-11-01T12:00:00+0000")
                  (title . "x")))))
    (should (string-match-p "\\`\\?  " label))))

(ert-deftest decknix-agent-review-followup-describe--missing-status ()
  "Missing status defaults to `open'."
  (let ((label (decknix--agent-review-followup-describe
                '((id . "fu-1")
                  (ts . "2025-11-01T12:00:00+0000")
                  (title . "x")))))
    (should (string-match-p " open " label))))

(ert-deftest decknix-agent-review-followup-describe--missing-title ()
  "Missing title renders the `(untitled)' placeholder."
  (let ((label (decknix--agent-review-followup-describe
                '((id . "fu-1")
                  (status . "open")
                  (ts . "2025-11-01T12:00:00+0000")))))
    (should (string-match-p "(untitled)\\'" label))))

(ert-deftest decknix-agent-review-followup-describe--done-status-face ()
  "`done' status carries `font-lock-comment-face'."
  (let* ((entry '((id . "fu-1")
                  (status . "done")
                  (ts . "2025-11-01T12:00:00+0000")
                  (title . "x")))
         (label (decknix--agent-review-followup-describe entry))
         ;; The status word `done' is the only `done' substring in the
         ;; label; locate it and read the face property at that point.
         (pos (string-match "done" label)))
    (should pos)
    (should (eq (get-text-property pos 'face label)
                'font-lock-comment-face))))

(ert-deftest decknix-agent-review-followup-describe--non-done-status-warning-face ()
  "Any non-`done' status carries `font-lock-warning-face' (incl. the
`open' default applied when the field is missing)."
  (dolist (status '("open" "blocked" nil))
    (let* ((entry (append (when status `((status . ,status)))
                          '((id . "fu-1")
                            (ts . "2025-11-01T12:00:00+0000")
                            (title . "x"))))
           (label (decknix--agent-review-followup-describe entry))
           (status-text (or status "open"))
           (pos (string-match (regexp-quote status-text) label)))
      (should pos)
      (should (eq (get-text-property pos 'face label)
                  'font-lock-warning-face)))))

(ert-deftest decknix-agent-review-followup-describe--bad-ts-falls-back ()
  "`date-to-time' raising on a malformed `ts' is swallowed by
`ignore-errors' so the formatter still returns a label.  The date
column falls back to `format-time-string' on nil (= current time),
so the value is non-empty and matches the `YYYY-MM-DD' shape."
  (let* ((entry '((id . "fu-1")
                  (status . "open")
                  (ts . "not-a-date")
                  (title . "x")))
         (label (decknix--agent-review-followup-describe entry)))
    (should (string-match-p "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" label))
    (should (string-match-p "x\\'" label))))

(ert-deftest decknix-agent-review-followup-describe--missing-ts ()
  "Missing `ts' uses the empty-string default; `date-to-time' on \"\"
errors and `ignore-errors' returns nil so the date column falls
back to current time."
  (let* ((entry '((id . "fu-1")
                  (status . "open")
                  (title . "x")))
         (label (decknix--agent-review-followup-describe entry)))
    (should (string-match-p "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" label))))

(provide 'decknix-agent-review-followup-format-test)
;;; decknix-agent-review-followup-format-test.el ends here
