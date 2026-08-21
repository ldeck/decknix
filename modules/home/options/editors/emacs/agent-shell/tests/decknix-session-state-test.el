;;; decknix-session-state-test.el --- Tests for the session-state classifier -*- lexical-binding: t -*-

;; Author: decknix
;; Package-Requires: ((emacs "29.1") (decknix-session-state "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;; ERT tests pinning `decknix-session-classify' and its accessors.

;;; Code:

(require 'ert)
(require 'decknix-session-state)

(defun decknix-session-state-test--classify (&rest signals)
  (decknix-session-classify signals))

(ert-deftest decknix-session-classify--empty-is-idle ()
  (let ((r (decknix-session-classify nil)))
    (should (eq (decknix-session-state r) 'idle))
    (should (= (decknix-session-score r) 10))))

(ert-deftest decknix-session-classify--busy-is-running ()
  (let ((r (decknix-session-state-test--classify :busy t)))
    (should (eq (decknix-session-state r) 'running))
    (should (= (decknix-session-score r) 30))))

(ert-deftest decknix-session-classify--unread-idle-is-review ()
  "Completed (not busy) with unread output is review."
  (let ((r (decknix-session-state-test--classify :unread t)))
    (should (eq (decknix-session-state r) 'review))
    (should (= (decknix-session-score r) 60))))

(ert-deftest decknix-session-classify--busy-beats-unread ()
  "A turn in progress is `running' even if earlier output is unread."
  (should (eq (decknix-session-state
               (decknix-session-state-test--classify :busy t :unread t))
              'running)))

(ert-deftest decknix-session-classify--attention-is-needs-input ()
  (let ((r (decknix-session-state-test--classify :attention t)))
    (should (eq (decknix-session-state r) 'needs-input))
    (should (= (decknix-session-score r) 70))))

(ert-deftest decknix-session-classify--permission-outranks-attention ()
  (let ((r (decknix-session-state-test--classify :attention t :awaiting-permission t)))
    (should (eq (decknix-session-state r) 'needs-input))
    (should (= (decknix-session-score r) 80))))

(ert-deftest decknix-session-classify--error-outranks-all ()
  (should (eq (decknix-session-state
               (decknix-session-state-test--classify
                :error t :awaiting-permission t :busy t :unread t))
              'error)))

(ert-deftest decknix-session-classify--done ()
  (let ((r (decknix-session-state-test--classify :done t)))
    (should (eq (decknix-session-state r) 'done))
    (should (= (decknix-session-score r) 0))))

(ert-deftest decknix-session-classify--needs-input-outranks-review ()
  "A pending decision beats reviewing completed output."
  (should (> (decknix-session-score
              (decknix-session-state-test--classify :awaiting-permission t))
             (decknix-session-score
              (decknix-session-state-test--classify :unread t)))))

(ert-deftest decknix-session-state-meta--glyph-and-label ()
  (should (equal (decknix-session-state-glyph 'needs-input) "⚠"))
  (should (equal (decknix-session-state-label 'running) "running"))
  (should (equal (decknix-session-state-glyph 'nonsense) "?"))
  (should (equal (decknix-session-state-label 'nonsense) "nonsense")))

;; -- status-string mapping (adapter input) -------------------------

(ert-deftest decknix-session-classify-status--vocabulary ()
  "Each agent-shell status string maps to the expected state."
  (should (eq (decknix-session-state (decknix-session-classify-status "killed"))   'error))
  (should (eq (decknix-session-state (decknix-session-classify-status "waiting"))  'needs-input))
  (should (eq (decknix-session-state (decknix-session-classify-status "working"))  'running))
  (should (eq (decknix-session-state (decknix-session-classify-status "finished")) 'review))
  (should (eq (decknix-session-state (decknix-session-classify-status "ready"))    'idle))
  (should (eq (decknix-session-state (decknix-session-classify-status "initializing")) 'idle)))

(ert-deftest decknix-session-classify-status--waiting-is-a-permission-block ()
  "\"waiting\" feeds `:awaiting-permission', not the generic `:attention'.
It had fed `:attention' — leaving `:awaiting-permission' with no feeder
at all and collapsing the classifier's top two non-error bands, so a
permission dialog blocking a live turn could not outrank anything else."
  (should (equal '(:awaiting-permission t)
                 (decknix-session-signals-from-status "waiting")))
  (should (eq 'needs-input (decknix-session-state
                            (decknix-session-classify-status "waiting")))))

(ert-deftest decknix-session-classify-status--asking ()
  "\"asking\" feeds the `:attention' signal the classifier always documented.
Before this existed, `:attention' was only ever set by a permission
prompt, so a session that ended its turn on a QUESTION reported plain
`ready' and sat there looking idle."
  (should (equal '(:attention t) (decknix-session-signals-from-status "asking")))
  (should (eq 'needs-input (decknix-session-state
                            (decknix-session-classify-status "asking"))))
  ;; Ranks above a merely-unread finished turn: one wants an answer, the
  ;; other only wants a glance.
  (should (> (decknix-session-score (decknix-session-classify-status "asking"))
             (decknix-session-score (decknix-session-classify-status "finished"))))
  ;; ...but below a permission prompt, which blocks the turn outright.
  (should (< (decknix-session-score (decknix-session-classify-status "asking"))
             (decknix-session-score (decknix-session-classify-status "waiting")))))

(ert-deftest decknix-session-classify-status--unknown-is-idle ()
  "An unrecognised status carries no signals and classifies as idle."
  (should (null (decknix-session-signals-from-status "wat")))
  (should (eq (decknix-session-state (decknix-session-classify-status "wat")) 'idle)))

(ert-deftest decknix-session-classify-status--closing ()
  "The \"closing\" status maps to the distinct `closing' state with its glyph."
  (should (equal '(:closing t) (decknix-session-signals-from-status "closing")))
  (should (eq 'closing (decknix-session-state (decknix-session-classify-status "closing"))))
  (should (string= "⏻" (decknix-session-state-glyph 'closing)))
  ;; low attention — below anything that needs you, but distinct from idle/done
  (should (< (decknix-session-score (decknix-session-classify-status "closing"))
             (decknix-session-score (decknix-session-classify-status "working")))))

(provide 'decknix-session-state-test)
;;; decknix-session-state-test.el ends here
