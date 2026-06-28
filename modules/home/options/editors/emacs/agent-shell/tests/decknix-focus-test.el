;;; decknix-focus-test.el --- Tests for decknix-focus -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-focus "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests pinning the pure decision layer of `decknix-focus' — the
;; 3-state cycle (off -> attention -> both), the state labels, the
;; attention/new-session predicates, the attention-edge detector, and
;; the per-buffer `note-status' detector that drives focus-stealing.
;;
;; The actual frame raise (`decknix-focus-raise-frame') is a side
;; effect; these tests stub it via a dynamic counter so the decision
;; logic can be verified without a live GUI frame.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-focus)

;; -- State cycle ----------------------------------------------------

(ert-deftest decknix-focus/next-state-cycles-all-three ()
  "`next-state' walks off -> attention -> both -> off."
  (should (eq 'attention (decknix-focus-next-state 'off)))
  (should (eq 'both      (decknix-focus-next-state 'attention)))
  (should (eq 'off       (decknix-focus-next-state 'both))))

(ert-deftest decknix-focus/next-state-unknown-resets-to-off ()
  "An unrecognised state resets the cycle to `off'."
  (should (eq 'off (decknix-focus-next-state 'garbage)))
  (should (eq 'off (decknix-focus-next-state nil))))

;; -- State labels ---------------------------------------------------

(ert-deftest decknix-focus/state-label-per-state ()
  "Each state has a stable short label."
  (should (string= "off"     (decknix-focus-state-label 'off)))
  (should (string= "attention" (decknix-focus-state-label 'attention)))
  (should (string= "att+new" (decknix-focus-state-label 'both))))

;; -- Predicates -----------------------------------------------------

(ert-deftest decknix-focus/attention-predicate ()
  "`steal-attention-p' is true for `attention' and `both' only."
  (let ((decknix-focus-steal 'off))      (should-not (decknix-focus-steal-attention-p)))
  (let ((decknix-focus-steal 'attention)) (should (decknix-focus-steal-attention-p)))
  (let ((decknix-focus-steal 'both))     (should (decknix-focus-steal-attention-p))))

(ert-deftest decknix-focus/new-session-predicate ()
  "`steal-new-session-p' is true only for `both'."
  (let ((decknix-focus-steal 'off))      (should-not (decknix-focus-steal-new-session-p)))
  (let ((decknix-focus-steal 'attention)) (should-not (decknix-focus-steal-new-session-p)))
  (let ((decknix-focus-steal 'both))     (should (decknix-focus-steal-new-session-p))))

;; -- Attention edge detector ----------------------------------------
;;
;; Contract: an "edge" into needs-attention is when the previous raw
;; status was NOT "waiting" and the new raw status IS "waiting".

(ert-deftest decknix-focus/attention-edge ()
  "Edge fires only on the transition into `waiting'."
  (should     (decknix-focus-attention-edge-p "working" "waiting"))
  (should     (decknix-focus-attention-edge-p nil       "waiting"))
  (should     (decknix-focus-attention-edge-p "ready"   "waiting"))
  (should-not (decknix-focus-attention-edge-p "waiting" "waiting"))
  (should-not (decknix-focus-attention-edge-p "working" "ready"))
  (should-not (decknix-focus-attention-edge-p "waiting" "ready")))

;; -- note-status detector -------------------------------------------
;;
;; `note-status' raises the frame when: the toggle enables attention
;; steal, the buffer is NOT currently visible/active, AND a fresh edge
;; into "waiting" occurred.  It always records the latest status so a
;; mid-wait toggle-on does not fire on an already-waiting session.

(defmacro decknix-focus-test--with-counter (&rest body)
  "Run BODY with `decknix-focus-raise-frame' counting into `calls'."
  (declare (indent 0))
  `(let ((calls 0))
     (cl-letf (((symbol-function 'decknix-focus-raise-frame)
                (lambda (&rest _) (setq calls (1+ calls)))))
       ,@body)))

(ert-deftest decknix-focus/note-status-fires-on-edge-when-enabled ()
  "Backgrounded session entering `waiting' raises when enabled."
  (decknix-focus-test--with-counter
    (with-temp-buffer
      (setq-local decknix-focus--last-status "working")
      (let ((decknix-focus-steal 'attention))
        (decknix-focus-note-status "waiting" nil)
        (should (= calls 1))
        ;; Idempotent: a second tick still "waiting" must not re-fire.
        (decknix-focus-note-status "waiting" nil)
        (should (= calls 1))))))

(ert-deftest decknix-focus/note-status-skips-when-visible ()
  "No steal when the session buffer is already the active buffer."
  (decknix-focus-test--with-counter
    (with-temp-buffer
      (setq-local decknix-focus--last-status "working")
      (let ((decknix-focus-steal 'attention))
        (decknix-focus-note-status "waiting" t)
        (should (= calls 0))))))

(ert-deftest decknix-focus/note-status-skips-when-off ()
  "No steal when the toggle is off, but status is still tracked."
  (decknix-focus-test--with-counter
    (with-temp-buffer
      (setq-local decknix-focus--last-status "working")
      (let ((decknix-focus-steal 'off))
        (decknix-focus-note-status "waiting" nil)
        (should (= calls 0))
        ;; Status tracked even when off, so a later toggle-on while
        ;; already waiting does not see a fresh edge.
        (should (string= "waiting" decknix-focus--last-status))))))

(ert-deftest decknix-focus/maybe-raise-on-new-session ()
  "`maybe-raise-on-new-session' raises only in `both' state."
  (decknix-focus-test--with-counter
    (let ((decknix-focus-steal 'attention))
      (decknix-focus-maybe-raise-on-new-session)
      (should (= calls 0)))
    (let ((decknix-focus-steal 'both))
      (decknix-focus-maybe-raise-on-new-session)
      (should (= calls 1)))))

(provide 'decknix-focus-test)
;;; decknix-focus-test.el ends here
