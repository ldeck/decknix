;;; decknix-agent-input-ring-test.el --- Tests for input-ring decisions -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-input-ring' (PR B.78).
;; Two pure helpers carved from
;; `decknix--agent-session-restore-input-ring':
;;
;;   `decknix--input-ring-required-size' -- ring-sizing rule:
;;     grow to fit PROMPT-COUNT but never below the existing
;;     CURRENT-SIZE (or the comint default 32 when nil).
;;
;;   `decknix--input-ring-insertion-order' -- reverses the
;;     newest-first PROMPTS list to oldest-first AND drops
;;     non-string / blank entries so `ring-insert' can be called
;;     unconditionally in the bulk caller.
;;
;; No comint dependency, no buffer state, no `make-ring' /
;; `ring-insert' -- the actual ring mutation stays in main-bulk
;; per AGENTS.md Rule 2.

;;; Code:

(require 'ert)
(require 'decknix-agent-input-ring)

;; --- required-size ---

(ert-deftest decknix-input-ring--required-size-nil-current-grows-to-prompts ()
  "Nil CURRENT defaults to the comint baseline (32); grows to PROMPT-COUNT."
  (should (= 50 (decknix--input-ring-required-size nil 50))))

(ert-deftest decknix-input-ring--required-size-nil-current-keeps-baseline ()
  "Nil CURRENT + small PROMPT-COUNT keeps the 32 baseline."
  (should (= 32 (decknix--input-ring-required-size nil 10))))

(ert-deftest decknix-input-ring--required-size-keeps-larger-current ()
  "Existing CURRENT larger than PROMPT-COUNT is preserved."
  (should (= 100 (decknix--input-ring-required-size 100 50))))

(ert-deftest decknix-input-ring--required-size-grows-past-current ()
  "PROMPT-COUNT larger than CURRENT grows the ring."
  (should (= 200 (decknix--input-ring-required-size 100 200))))

(ert-deftest decknix-input-ring--required-size-zero-prompts-keeps-current ()
  "Zero PROMPT-COUNT keeps whatever CURRENT was (or baseline if nil)."
  (should (= 32 (decknix--input-ring-required-size nil 0)))
  (should (= 64 (decknix--input-ring-required-size 64 0))))

;; --- insertion-order ---

(ert-deftest decknix-input-ring--insertion-order-reverses-newest-first ()
  "Newest-first input becomes oldest-first output."
  (should (equal '("c" "b" "a")
                 (decknix--input-ring-insertion-order '("a" "b" "c")))))

(ert-deftest decknix-input-ring--insertion-order-drops-empty-strings ()
  "Empty strings are filtered out."
  (should (equal '("b" "a")
                 (decknix--input-ring-insertion-order '("a" "" "b")))))

(ert-deftest decknix-input-ring--insertion-order-drops-whitespace-only ()
  "Whitespace-only strings are filtered out (string-trim semantics)."
  (should (equal '("b" "a")
                 (decknix--input-ring-insertion-order '("a" "  \n\t" "b")))))

(ert-deftest decknix-input-ring--insertion-order-drops-non-strings ()
  "Non-string entries are filtered out (defensive against malformed JSON)."
  (should (equal '("a")
                 (decknix--input-ring-insertion-order '(nil "a" 42)))))

(ert-deftest decknix-input-ring--insertion-order-empty-input ()
  "Empty list returns empty list."
  (should (equal nil
                 (decknix--input-ring-insertion-order '()))))

(ert-deftest decknix-input-ring--insertion-order-does-not-mutate-input ()
  "Input list is not destructively modified (callers may reuse it)."
  (let* ((input (list "a" "b" "c"))
         (snapshot (copy-sequence input)))
    (decknix--input-ring-insertion-order input)
    (should (equal snapshot input))))


;; -- seeding a RESUMED buffer -----------------------------------------
;;
;; The seeding guard was `ring-empty-p' alone, which did nothing on the
;; case it existed for.  By the time the resume timer runs, comint has
;; already inherited the shared history, so the ring is not empty and the
;; session's own prompts were never loaded.  Measured on a live pi
;; session: 3 user entries in the transcript, 187 entries in the ring --
;; `M-p' cycled other sessions' prompts.

(ert-deftest decknix-input-ring/seeds-a-resumed-buffer-with-inherited-history ()
  "A non-empty (inherited) ring must NOT stop the session seeding."
  (should (decknix--input-ring-should-seed-p nil nil)))

(ert-deftest decknix-input-ring/seeds-an-empty-ring ()
  "The original case still seeds."
  (should (decknix--input-ring-should-seed-p t nil)))

(ert-deftest decknix-input-ring/never-seeds-twice ()
  "Once seeded, later passes leave the ring alone.
This is what protects prompts the user types after resume -- the concern
the `ring-empty-p' guard was reaching for."
  (should-not (decknix--input-ring-should-seed-p nil t))
  (should-not (decknix--input-ring-should-seed-p t t)))

(provide 'decknix-agent-input-ring-test)
;;; decknix-agent-input-ring-test.el ends here
