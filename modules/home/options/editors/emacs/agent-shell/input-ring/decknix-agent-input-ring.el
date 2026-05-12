;;; decknix-agent-input-ring.el --- Input-ring sizing & ordering rules -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, comint, history

;;; Commentary:
;;
;; Pure decision helpers for `comint-input-ring' restoration on
;; session resume (PR B.78).  Carved out of
;; `decknix--agent-session-restore-input-ring' so the two domain
;; rules -- ring-sizing and prompt-ordering -- can be exercised
;; without a comint buffer.
;;
;; Public surface (two pure functions):
;;
;;   `decknix--input-ring-required-size' (current-size prompt-count)
;;     -- returns the size the ring must grow to so it can hold
;;        PROMPT-COUNT entries.  Never shrinks an existing ring;
;;        falls back to the comint baseline (32) when CURRENT-SIZE
;;        is nil so a brand-new comint buffer still gets the
;;        upstream default when the session has fewer prompts.
;;
;;   `decknix--input-ring-insertion-order' (prompts)
;;     -- transforms the newest-first PROMPTS list (as returned by
;;        `decknix--prompt-extract-from-file') into the
;;        oldest-first list of trimmed-non-empty strings the bulk
;;        caller passes to `ring-insert'.  Drops nil, non-strings,
;;        empty strings, and whitespace-only entries.  Does NOT
;;        mutate PROMPTS so callers may reuse the source list.
;;
;; Non-goals (stay in main-bulk per AGENTS.md Rule 2):
;;   * Reading the session JSON file
;;   * `make-ring' / `setq-local' on `comint-input-ring*'
;;   * Iterating + calling `ring-insert' for each prompt
;;
;; The bulk caller composes these two helpers around its
;; comint-side mutation:
;;
;;   (when (and ring (ring-empty-p ring))
;;     (let* ((prompts (read-prompts-from-file file))
;;            (n       (decknix--input-ring-required-size
;;                      comint-input-ring-size (length prompts)))
;;            (ordered (decknix--input-ring-insertion-order prompts)))
;;       (setq-local comint-input-ring-size n)
;;       (setq-local comint-input-ring (make-ring n))
;;       (dolist (p ordered) (ring-insert ring p))))

;;; Code:

(defconst decknix--input-ring-default-size 32
  "Comint's baseline `comint-input-ring-size' fallback.
Used when `comint-input-ring-size' is nil so a freshly-created
ring still gets the upstream default.  Pinned here so the
bulk caller and the test fixture share one source of truth.")

(defun decknix--input-ring-required-size (current-size prompt-count)
  "Return the ring size needed to hold PROMPT-COUNT entries.

CURRENT-SIZE is the existing `comint-input-ring-size' (or nil if
the ring has never been sized).  Result is the larger of the two
inputs, with `decknix--input-ring-default-size' substituted for a
nil CURRENT-SIZE so we never shrink below the comint baseline."
  (max (or current-size decknix--input-ring-default-size)
       prompt-count))

(defun decknix--input-ring-insertion-order (prompts)
  "Return PROMPTS in the order `ring-insert' should receive them.

PROMPTS is the newest-first list returned by
`decknix--prompt-extract-from-file'.  The result is the
oldest-first sub-list with non-strings and trimmed-empty entries
filtered out.  When the bulk caller passes each element to
`ring-insert' in turn, the newest prompt ends up at ring index 0
-- matching how `comint-read-input-ring' loads from a history
file.

PROMPTS is not mutated; the caller's list is left intact."
  (let ((acc nil))
    (dolist (p prompts)
      (when (and (stringp p)
                 (not (string-empty-p (string-trim p))))
        (push p acc)))
    acc))

(provide 'decknix-agent-input-ring)
;;; decknix-agent-input-ring.el ends here
