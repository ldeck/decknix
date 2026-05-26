;;; decknix-picker-selections.el --- Coerce embark selections to a flat cand list -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, embark, multi-select

;;; Commentary:
;;
;; Pure helper that normalises the return value of
;; `embark-selected-candidates' into a flat list of bare candidate
;; strings the session picker can iterate.
;;
;; `embark-selected-candidates' returns `(TYPE . CANDS)' where TYPE is
;; the multi-category symbol (e.g. `agent-session-saved') and CANDS is
;; the list of bare candidate strings (or `multi-category' when the
;; marked items span multiple sources).  The session picker stores the
;; captured value in `decknix--session-picker-captured-selections' and
;; later iterates it through `decknix--session-picker-dispatch'; if the
;; outer `(TYPE . CANDS)' cons is iterated as-is, the leading TYPE
;; symbol is fed to `gethash' (which returns nil for a symbol against
;; string-keyed maps) and dispatch silently no-ops on it.  Worse, the
;; original `(length sels)' multi-mode guard over-counts by one for
;; this same reason -- `(length (cons 'foo '(...)))' counts the cdr's
;; elements plus the leading symbol.
;;
;; This module owns the unwrap so the picker call site stays small and
;; the contract is independently testable without a live minibuffer.
;;
;; The coerce is intentionally tolerant of upstream shape changes:
;;
;;   nil                   -> nil                  (no marked items)
;;   (TYPE . CANDS)        -> CANDS                (current embark shape)
;;   bare-list-of-strings  -> the list unchanged   (defensive fallback)
;;
;; The third clause keeps the picker working if a future embark
;; release flips back to returning just the candidate list -- we don't
;; want a silent regression on the call site.

;;; Code:

(defun decknix-picker-selections-coerce (raw)
  "Return a flat list of bare candidates from RAW.
RAW is the value returned by `embark-selected-candidates'.  See the
file commentary for the three shapes this function accepts."
  (cond
   ((null raw) nil)
   ;; Current embark shape: (TYPE . CANDS) where TYPE is a symbol.
   ;; The leading symbol distinguishes this from a flat list of
   ;; propertized candidate strings (whose car would be a string).
   ((and (consp raw) (symbolp (car raw)))
    (cdr raw))
   ;; Defensive: any other proper list shape passes through unchanged.
   ((listp raw) raw)
   ;; Single non-list value: wrap in a list so callers can `dolist'.
   (t (list raw))))

(provide 'decknix-picker-selections)
;;; decknix-picker-selections.el ends here
