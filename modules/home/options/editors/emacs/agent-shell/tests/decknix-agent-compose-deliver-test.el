;;; decknix-agent-compose-deliver-test.el --- Interrupt-then-submit never drops a prompt -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Reported 2026-10-26: "opening the compose window and choosing to
;; interrupt and submit ... seems to interrupt but not submit the message."
;;
;; The C-c C-c busy prompt's `i' branch closed the compose buffer BEFORE the
;; post-interrupt wait, and the wait's callback refused to send into a
;; still-busy shell.  So whenever the interrupted turn had not ended inside
;; the budget, the cancel went out, the prompt went nowhere, and the only
;; copy was on the kill ring, with no message.  claude-agent-acp 0.94 can
;; take up to its 30 s force-cancel backstop to end a wedged turn, and a
;; cancel that never reaches a live turn never ends it at all.
;;
;; The fake session below plays the agent-shell side: an ACP `session/prompt'
;; result (any stopReason) or error runs `shell-maker-finish-output', which
;; is what clears `shell-maker--busy' (agent-shell.el `on-success' and
;; `agent-shell--make-error-handler').  The response shapes are the ones the
;; two bridges send for a cancelled turn.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-compose-wait)
(require 'decknix-agent-compose-queue)
(require 'decknix-agent-compose-busy)
(require 'decknix-agent-compose-history)
(require 'decknix-agent-shell-main-compose)

(defvar shell-maker--busy nil)
(defvar decknix-compose-interrupt-budget)

(defconst decknix-deliver-test--claude-cancel
  '((stopReason . "cancelled")
    (usage (inputTokens . 8) (outputTokens . 5119))
    (_meta (quota (token_count (totalTokens . 1008996)))))
  "claude-agent-acp 0.94 result for a cancelled `session/prompt'.")

(defconst decknix-deliver-test--pi-cancel
  '((stopReason . "cancelled"))
  "pi-acp 0.0.34 result for a cancelled `session/prompt'.")

(defconst decknix-deliver-test--rejected
  '((code . -32800) (message . "Request cancelled"))
  "An ACP error for the prompt, the on-failure path.")

(defun decknix-deliver-test--acp-turn-end (buffer _response)
  "Play agent-shell receiving RESPONSE for BUFFER's in-flight prompt.
Every result shape and every error ends in `shell-maker-finish-output'."
  (with-current-buffer buffer
    (setq-local shell-maker--busy nil)))

(defmacro decknix-deliver-test--with-session (spec &rest body)
  "Run BODY with a fake busy session and recorded side effects.
SPEC is (TARGET COMPOSE SUBMITTED INTERRUPTS TICK CLOCK).  TARGET is a busy
agent buffer with a live process; COMPOSE a compose buffer aimed at it.
SUBMITTED collects `shell-maker-submit' inputs, INTERRUPTS counts
`agent-shell-interrupt' calls.  (funcall TICK) runs the next scheduled wait
tick; (setq CLOCK N) moves the wait's clock to N seconds."
  (declare (indent 1))
  (pcase-let ((`(,target ,compose ,submitted ,interrupts ,tick ,clock) spec))
    `(let* ((,target (generate-new-buffer " *deliver-target*"))
            (,compose (generate-new-buffer " *deliver-compose*"))
            (,submitted nil)
            (,interrupts 0)
            (,clock 0.0)
            (scheduled nil)
            (proc (make-pipe-process :name "deliver-test" :buffer ,target
                                     :noquery t)))
       (unwind-protect
           (cl-letf (((symbol-function 'run-at-time)
                      (lambda (_when repeat fn &rest _)
                        (unless repeat (setq scheduled (append scheduled (list fn))))
                        (list 'mock-timer)))
                     ((symbol-function 'cancel-timer) #'ignore)
                     ((symbol-function 'timerp)
                      (lambda (o) (and (consp o) (eq (car o) 'mock-timer))))
                     ((symbol-function 'float-time)
                      (lambda (&rest _) ,clock))
                     ((symbol-function 'shell-maker-submit)
                      (lambda (&rest args)
                        (push (plist-get args :input) ,submitted)))
                     ((symbol-function 'agent-shell-interrupt)
                      (lambda (&rest _) (cl-incf ,interrupts)))
                     ;; The broker status still says "working" for a while
                     ;; after the turn ends (its reprobe floor); delivery
                     ;; must key on the turn ending, not on this.
                     ((symbol-function 'decknix--compose-queue-status)
                      (lambda () "working"))
                     ((symbol-function 'message) #'ignore))
             (with-current-buffer ,target
               (setq-local shell-maker--busy t))
             (with-current-buffer ,compose
               (insert "please stop and look at this instead")
               (setq-local decknix--compose-target-buffer ,target))
             (let ((,tick (lambda ()
                            (let ((fn (pop scheduled)))
                              (should fn)
                              (funcall fn)))))
               ,@body))
         (when (process-live-p proc) (delete-process proc))
         (when (buffer-live-p ,target)
           (with-current-buffer ,target
             (setq decknix--compose-queue-timer nil))
           (kill-buffer ,target))
         (when (buffer-live-p ,compose) (kill-buffer ,compose))))))

(defun decknix-deliver-test--interrupt-submit-via-busy-prompt (compose)
  "Run C-c C-c in COMPOSE and answer the busy prompt with `i'."
  (cl-letf (((symbol-function 'read-char-choice) (lambda (&rest _) ?i)))
    (with-current-buffer compose
      (decknix-agent-compose-submit))))

;; -- the cancel ends the turn: submit, for each bridge's shape --------

(dolist (case `((claude . ,decknix-deliver-test--claude-cancel)
                (pi . ,decknix-deliver-test--pi-cancel)
                (rejected . ,decknix-deliver-test--rejected)))
  (let ((name (intern (format "decknix-compose-deliver/busy-prompt-i-submits-after-%s-cancel"
                              (car case))))
        (response (cdr case)))
    (eval
     `(ert-deftest ,name ()
        "C-c C-c then `i': the prompt is sent once the cancel ends the turn."
        (decknix-deliver-test--with-session
            (target compose submitted interrupts tick clock)
          (decknix-deliver-test--interrupt-submit-via-busy-prompt compose)
          (should (= 1 interrupts))
          (funcall tick)
          (should-not submitted)
          (setq clock 0.3)
          (decknix-deliver-test--acp-turn-end target ',response)
          (funcall tick)
          (should-not submitted)
          (setq clock 0.7)
          (funcall tick)
          (should (equal '("please stop and look at this instead") submitted))
          (should-not (buffer-live-p compose))))
     t)))

(ert-deftest decknix-compose-deliver/interrupt-and-submit-command-submits ()
  "The dedicated interrupt-and-submit command takes the same path."
  (decknix-deliver-test--with-session
      (target compose submitted interrupts tick clock)
    (with-current-buffer compose
      (decknix-agent-compose-interrupt-and-submit))
    (should (= 1 interrupts))
    (decknix-deliver-test--acp-turn-end target decknix-deliver-test--pi-cancel)
    (setq clock 1.0)
    (funcall tick)
    (should (equal '("please stop and look at this instead") submitted))))

;; -- the cancel is not acknowledged in time: queue, never drop --------

(ert-deftest decknix-compose-deliver/unacked-cancel-queues-then-sends ()
  "Still busy at the budget: queued first and released, compose consumed,
then sent by the queue poller when the turn finally ends.  Before the fix
nothing was sent or queued and the compose buffer was already gone."
  (decknix-deliver-test--with-session
      (target compose submitted interrupts tick clock)
    (with-current-buffer target
      (setq-local decknix--compose-queued-prompt '("older queued")))
    (cl-letf (((symbol-function 'decknix--compose-queue-interrupt-action)
               (lambda (_) 'first)))
      (decknix-deliver-test--interrupt-submit-via-busy-prompt compose))
    (funcall tick)
    (setq clock (+ decknix-compose-interrupt-budget 0.1))
    (funcall tick)
    (should-not submitted)
    (with-current-buffer target
      (should (equal '("please stop and look at this instead" "older queued")
                     decknix--compose-queued-prompt))
      (should decknix--compose-queue-release))
    (should-not (buffer-live-p compose))
    (decknix-deliver-test--acp-turn-end target decknix-deliver-test--claude-cancel)
    (with-current-buffer target
      (decknix--compose-queue-poll))
    (should (equal '("please stop and look at this instead") submitted))))

(ert-deftest decknix-compose-deliver/gone-session-keeps-compose-text ()
  "A session whose process died keeps the text in the compose buffer."
  (decknix-deliver-test--with-session
      (target compose submitted interrupts tick clock)
    (with-current-buffer compose
      (decknix-agent-compose-interrupt-and-submit))
    (delete-process (get-buffer-process target))
    (setq clock 1.0)
    (decknix-deliver-test--acp-turn-end target decknix-deliver-test--claude-cancel)
    (funcall tick)
    (should-not submitted)
    (should (buffer-live-p compose))
    (should (equal "please stop and look at this instead"
                   (with-current-buffer compose (buffer-string))))))

(provide 'decknix-agent-compose-deliver-test)
;;; decknix-agent-compose-deliver-test.el ends here
