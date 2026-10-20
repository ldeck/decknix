;;; decknix-agent-turn-working-test.el --- `working' refinement -*- lexical-binding: t -*-

;;; Commentary:
;;
;; A session reattached to a still-running broker reported `ready' and so
;; read as dormant while its agent was producing output.  The precedence
;; between `working' and `asking' is the part worth pinning: a question
;; closes a turn, so an agent mid-turn cannot also be asking, and getting
;; it the wrong way round would park a working session under "needs you".

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-turn-signals)

(ert-deftest decknix-working--beats-asking ()
  "Both facts present: mid-turn wins, because a question only ever closes
a turn that has finished."
  (should (equal "working"
                 (decknix-agent-turn-status
                  "ready" '(:working t :question t)))))

(ert-deftest decknix-working--refines-a-settled-status ()
  (should (equal "working" (decknix-agent-turn-status "ready" '(:working t))))
  (should (equal "working" (decknix-agent-turn-status "finished" '(:working t)))))

(ert-deftest decknix-working--never-overrides-a-more-specific-block ()
  "`waiting' is a permission prompt and `netfail' a dead connection; both
are more specific than `working' and must survive."
  (dolist (raw '("waiting" "netfail" "closing"))
    (should (equal raw (decknix-agent-turn-status raw '(:working t))))))

(ert-deftest decknix-working--asking-still-works-without-the-new-fact ()
  "The pre-existing refinement must not regress."
  (should (equal "asking" (decknix-agent-turn-status "ready" '(:question t)))))

(ert-deftest decknix-working--no-facts-changes-nothing ()
  (should (equal "ready" (decknix-agent-turn-status "ready" nil))))

;; The broker is re-read at most every few seconds, so just after a turn
;; ends it can still say the turn is in flight.  A board refreshed then
;; kept a session that had reached its gate under In progress.

(ert-deftest decknix-working--a-turn-this-buffer-saw-end-is-not-working ()
  (should (equal "asking"
                 (decknix-agent-turn-status
                  "ready" '(:working t :ended t :question t))))
  (should (equal "ready"
                 (decknix-agent-turn-status "ready" '(:working t :ended t)))))

(ert-deftest decknix-working--ended-is-set-at-turn-end-and-cleared-by-input ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t)))
      (setq decknix--agent-turn-message-tail "Ready to submit? (yes / edit / cancel)")
      (decknix--agent-turn-observe-event :event 'turn-complete :data nil)
      (should (plist-get (decknix-agent-turn-facts) :ended))
      (decknix--agent-turn-observe-event :event 'input-submitted :data nil)
      (should-not (plist-get (decknix-agent-turn-facts) :ended))
      (should (equal "working"
                     (decknix-agent-turn-status
                      "ready" (append '(:working t) (decknix-agent-turn-facts))))))))

(provide 'decknix-agent-turn-working-test)
;;; decknix-agent-turn-working-test.el ends here
