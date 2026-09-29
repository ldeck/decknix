;;; decknix-agent-compose-queue-test.el --- Tests for compose-queue policy -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-compose-queue'
;; (PR B.79).  Verifies the action-resolver's decision table
;; matches the original `decknix--compose-queue-poll' nesting.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-compose-queue)

(ert-deftest decknix-compose-queue--dead-buffer-cancels ()
  "Dead buffer always returns `cancel-timer', regardless of other inputs."
  (should (equal '(:action cancel-timer)
                 (decknix--compose-queue-action "p" nil nil t)))
  (should (equal '(:action cancel-timer)
                 (decknix--compose-queue-action nil nil t t)))
  (should (equal '(:action cancel-timer)
                 (decknix--compose-queue-action "p" nil t nil))))

(ert-deftest decknix-compose-queue--no-queue-waits ()
  "Live buffer with nothing queued waits even when idle."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action nil t nil t))))

(ert-deftest decknix-compose-queue--busy-waits ()
  "Live buffer with queued prompt but agent busy waits."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action "p" t t t))))

(ert-deftest decknix-compose-queue--no-process-waits ()
  "Live buffer with queued prompt but dead process waits."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action "p" t nil nil))))

(ert-deftest decknix-compose-queue--idle-and-queued-submits ()
  "Live buffer + queued + idle + live process -> submit with the input.
The bare string is the pre-list queue shape, still accepted so an upgrade
mid-flight submits it rather than dropping it."
  (should (equal '(:action submit :input "hello world" :rest nil)
                 (decknix--compose-queue-action
                  "hello world" t nil t))))

(ert-deftest decknix-compose-queue--submit-preserves-input-string ()
  "Submit action returns the exact input string (not mutated)."
  (let* ((input "multi\nline\nprompt")
         (result (decknix--compose-queue-action input t nil t)))
    (should (eq input (plist-get result :input)))))

(ert-deftest decknix-compose-queue--empty-string-queue-still-submits ()
  "Empty-string queue is treated as queued (caller's responsibility to filter).
Documents the boundary: the policy doesn't second-guess the queue
contents, so an empty queued prompt would still trigger submit."
  (should (equal '(:action submit :input "" :rest nil)
                 (decknix--compose-queue-action "" t nil t))))


;; -- multiple queued messages ------------------------------------------
;;
;; The queue was a single string set with `setq', so queueing a second
;; message before the first fired destroyed the first with no warning and no
;; way to see it had gone.

(ert-deftest decknix-compose-queue--append-keeps-both ()
  "Appending is the fix for the overwrite; order is submission order."
  (should (equal '("first" "second")
                 (decknix--compose-queue-append '("first") "second")))
  (should (equal '("only") (decknix--compose-queue-append nil "only"))))

(ert-deftest decknix-compose-queue--append-upgrades-a-single-slot ()
  "A queue captured in the old string shape must not be dropped."
  (should (equal '("old" "new")
                 (decknix--compose-queue-append "old" "new"))))

(ert-deftest decknix-compose-queue--submits-the-head-and-keeps-the-tail ()
  "One turn at a time, in order, with the remainder handed back."
  (should (equal '(:action submit :input "a" :rest ("b" "c"))
                 (decknix--compose-queue-action '("a" "b" "c") t nil t))))

(ert-deftest decknix-compose-queue--last-entry-leaves-an-empty-rest ()
  "The caller cancels its timer on an empty `:rest', so it must be nil."
  (should (equal '(:action submit :input "a" :rest nil)
                 (decknix--compose-queue-action '("a") t nil t))))

;; -- the question gate -------------------------------------------------
;;
;; A turn that ended by asking you something is a FINISHED turn, so
;; `shell-maker--busy' is already clear and the queued prompt went straight
;; into the answer slot.

(ert-deftest decknix-compose-queue--holds-when-the-turn-ended-on-a-question ()
  (should (equal '(:action hold :input "a" :reason "asking")
                 (decknix--compose-queue-action '("a") t nil t "asking"))))

(ert-deftest decknix-compose-queue--holds-on-a-pending-permission-prompt ()
  (should (equal '(:action hold :input "a" :reason "waiting")
                 (decknix--compose-queue-action '("a") t nil t "waiting"))))

(ert-deftest decknix-compose-queue--ordinary-statuses-do-not-hold ()
  "Only the two needs-input statuses block; an unknown one must not stall
the queue indefinitely, since running unattended is its whole purpose."
  (dolist (status '("ready" "finished" "closing" "initializing"
                    "something-new" nil))
    (should (eq 'submit
                (plist-get (decknix--compose-queue-action
                            '("a") t nil t status)
                           :action)))))

(ert-deftest decknix-compose-queue--an-empty-queue-never-holds ()
  "A hold with nothing to hold would report a stall that does not exist."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action nil t nil t "asking"))))

(ert-deftest decknix-compose-queue--busy-outranks-the-question-gate ()
  "Still working: that is a plain wait, not a hold needing the user."
  (should (equal '(:action wait)
                 (decknix--compose-queue-action '("a") t t t "asking"))))

;; -- drop / combine / labels -------------------------------------------

(ert-deftest decknix-compose-queue--drop-removes-just-that-entry ()
  (should (equal '("a" "c") (decknix--compose-queue-drop '("a" "b" "c") 1)))
  (should (equal '("b" "c") (decknix--compose-queue-drop '("a" "b" "c") 0)))
  (should (equal '("a" "b") (decknix--compose-queue-drop '("a" "b" "c") 2))))

(ert-deftest decknix-compose-queue--drop-out-of-range-changes-nothing ()
  "A stale completion selection must not silently drop the wrong message."
  (should (equal '("a" "b") (decknix--compose-queue-drop '("a" "b") 5)))
  (should (equal '("a" "b") (decknix--compose-queue-drop '("a" "b") -1)))
  (should (equal '("a" "b") (decknix--compose-queue-drop '("a" "b") nil))))

(ert-deftest decknix-compose-queue--combine-separates-by-a-blank-line ()
  "Two paragraphs, not one run-on sentence."
  (should (equal "a\n\nb" (decknix--compose-queue-combine '("a" "b"))))
  (should (equal "a|b" (decknix--compose-queue-combine '("a" "b") "|")))
  (should-not (decknix--compose-queue-combine nil)))

(ert-deftest decknix-compose-queue--summary-names-the-hold ()
  "A queue that has silently stopped moving is worse than none."
  (should (equal "2 queued" (decknix--compose-queue-summary '("a" "b"))))
  (should (equal "1 queued, held (asking)"
                 (decknix--compose-queue-summary '("a") "asking")))
  (should-not (decknix--compose-queue-summary nil)))

(ert-deftest decknix-compose-queue--entry-label-is-one-selectable-line ()
  "A multi-line prompt has to stay pickable in the minibuffer."
  (should (equal "1: one two" (decknix--compose-queue-entry-label "one\ntwo" 0)))
  (should (equal "2: ab…" (decknix--compose-queue-entry-label "abc" 1 2))))


;; -- drain and split: the turn boundary --------------------------------
;;
;; A drained queue has to come back as N turns, not one, so the boundary is a
;; real marker rather than presentation.  `---' (a markdown rule) rather than
;; a blank line, because a blank line separates paragraphs INSIDE one turn --
;; which is what keeps `combine' a real combine.

(ert-deftest decknix-compose-queue--drain-round-trips ()
  "split(drain(q)) = q.  If this breaks, editing a queue silently reorders
or merges the user's messages."
  (dolist (queue '(("a") ("a" "b") ("one" "two" "three")
                   ("multi\nline" "second")))
    (should (equal queue
                   (decknix--compose-queue-split-text
                    (decknix--compose-queue-drain-text queue))))))

(ert-deftest decknix-compose-queue--drain-of-empty-is-nil ()
  (should-not (decknix--compose-queue-drain-text nil)))

(ert-deftest decknix-compose-queue--boundary-must-be-its-own-line ()
  "A rule inside prose is not a boundary; an em-dash-ish run is not either."
  (should (equal '("a --- b") (decknix--compose-queue-split-text "a --- b")))
  (should (equal '("a\n----\nb") (decknix--compose-queue-split-text "a\n----\nb"))))

(ert-deftest decknix-compose-queue--boundary-tolerates-surrounding-space ()
  (should (equal '("a" "b") (decknix--compose-queue-split-text "a\n  ---  \nb"))))

(ert-deftest decknix-compose-queue--stray-rules-yield-no-empty-turn ()
  "Deleting a turn's body leaves two rules together; an empty prompt must
not be queued from that."
  (should (equal '("a" "b")
                 (decknix--compose-queue-split-text "---\na\n---\n---\nb\n---")))
  (should-not (decknix--compose-queue-split-text "---\n\n---")))

(ert-deftest decknix-compose-queue--combine-output-cannot-be-resplit ()
  "`j' means one turn.  If combine used the boundary, a later drain would
split it back apart and combine would not mean anything."
  (let ((combined (decknix--compose-queue-combine '("a" "b"))))
    (should (equal (list combined)
                   (decknix--compose-queue-split-text combined)))))

;; -- the enqueue prompt ------------------------------------------------

(ert-deftest decknix-compose-queue--enqueue-does-not-ask-on-an-empty-queue ()
  "The question exists because a second message used to destroy the first.
At zero there is nothing to destroy, so asking would just be friction."
  (cl-letf (((symbol-function 'read-char-choice)
             (lambda (&rest _) (error "must not prompt"))))
    (should (eq 'append (decknix--compose-queue-enqueue-action 0)))
    (should (eq 'append (decknix--compose-queue-enqueue-action nil)))))

(ert-deftest decknix-compose-queue--enqueue-maps-every-key ()
  (dolist (pair '((?a . append) (?r . replace) (?j . combine) (?c . cancel)))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (&rest _) (car pair))))
      (should (eq (cdr pair) (decknix--compose-queue-enqueue-action 2))))))

;; -- the interrupt prompt ----------------------------------------------

(ert-deftest decknix-compose-queue--interrupt-does-not-ask-without-a-queue ()
  (cl-letf (((symbol-function 'read-char-choice)
             (lambda (&rest _) (error "must not prompt"))))
    (should (eq 'first (decknix--compose-queue-interrupt-action 0)))
    (should (eq 'first (decknix--compose-queue-interrupt-action nil)))))

(ert-deftest decknix-compose-queue--interrupt-maps-every-key ()
  "`first' is the old behaviour, now named rather than silent: the new
message ran first and the older queued ones followed behind it."
  (dolist (pair '((?f . first) (?o . only) (?l . last) (?c . cancel)))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (&rest _) (car pair))))
      (should (eq (cdr pair) (decknix--compose-queue-interrupt-action 3))))))

(provide 'decknix-agent-compose-queue-test)
;;; decknix-agent-compose-queue-test.el ends here
