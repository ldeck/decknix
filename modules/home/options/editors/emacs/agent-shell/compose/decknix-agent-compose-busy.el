;;; decknix-agent-compose-busy.el --- Compose busy-prompt dispatch -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, compose

;;; Commentary:
;;
;; Pure dispatch helper for `decknix-agent-compose-submit' (in
;; main-bulk).  Maps the agent-busy state plus the user's
;; `read-char-choice' answer to one of four action symbols, so the
;; submit handler can `pcase' over a flat enum instead of
;; `cl-return-from'-ing out of nested branches.  Carved out of
;; main-bulk so the dispatch table is independently testable -- a
;; previous version used `cl-return-from' inside a plain `defun'
;; (no implicit `cl-block'), which threw `No catch for tag:
;; --cl-block-decknix-agent-compose-submit--' the moment the user
;; chose `?q' on the busy prompt.  Pinning the dispatch as an enum
;; here means future refactors of the surrounding submit logic
;; can't reintroduce that bug class.
;;
;; Public surface:
;;
;;   `decknix--compose-busy-action' (busy-p) -- one of the symbols
;;     `submit'           agent idle, no prompt needed
;;     `interrupt-submit' user chose `?i' (interrupt then submit)
;;     `queue'            user chose `?q' (queue for later)
;;     `cancel'           user chose `?c' (abort)
;;
;; The single side-effect is the `read-char-choice' call when
;; BUSY-P is non-nil; tests stub it via `cl-letf' so the suite
;; never blocks on a live minibuffer.

;;; Code:

(require 'cl-lib)

(defconst decknix--compose-busy-prompt
  "Agent is busy: [i]nterrupt & submit  [q]ueue for later  [c]ancel "
  "Prompt string shown by `decknix--compose-busy-action' when the
agent is busy.  Defined as a `defconst' so the test suite can
reach in and assert on the wording without duplicating it; the
production caller never reads this directly.")

(defun decknix--compose-busy-action (busy-p)
  "Return the dispatch symbol for the compose busy-prompt flow.
If BUSY-P is nil the agent is idle and the answer is `submit' --
the caller falls through to the normal submit path with no user
interaction.  Otherwise prompts the user with `read-char-choice'
and returns one of:

  `interrupt-submit'  user pressed `?i'
  `queue'             user pressed `?q'
  `cancel'            user pressed `?c'

Pure relative to `read-char-choice' (which the test suite stubs);
no buffer reads, no global state, no side-effects beyond the
prompt."
  (if (not busy-p)
      'submit
    (pcase (read-char-choice decknix--compose-busy-prompt
                             '(?i ?q ?c))
      (?i 'interrupt-submit)
      (?q 'queue)
      (?c 'cancel))))

(provide 'decknix-agent-compose-busy)
;;; decknix-agent-compose-busy.el ends here
