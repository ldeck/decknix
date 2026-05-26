;;; decknix-picker-selections-test.el --- Tests for picker selections coerce -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-picker-selections-coerce', the
;; pure helper that normalises `embark-selected-candidates' return
;; values into a flat list of bare candidate strings the session
;; picker dispatch can iterate.
;;
;; Pins the contract the session picker depends on so a future change
;; to embark's return shape (or to the helper) is caught by the build
;; rather than by the user discovering RET-does-nothing in the
;; minibuffer.

;;; Code:

(require 'ert)
(require 'decknix-picker-selections)

(ert-deftest decknix-picker-selections--nil-input ()
  "No marked items -> nil."
  (should (null (decknix-picker-selections-coerce nil))))

(ert-deftest decknix-picker-selections--type-cons-single-cand ()
  "Single-source single selection: leading TYPE stripped, one cand returned."
  (should (equal '("session-foo")
                 (decknix-picker-selections-coerce
                  '(agent-session-saved "session-foo")))))

(ert-deftest decknix-picker-selections--type-cons-multiple-cands ()
  "Single-source multi-selection: TYPE stripped, all cands preserved in order."
  (should (equal '("a" "b" "c")
                 (decknix-picker-selections-coerce
                  '(agent-session-saved "a" "b" "c")))))

(ert-deftest decknix-picker-selections--multi-category-shape ()
  "Mixed-source selection: `multi-category' is the leading symbol; still stripped."
  (should (equal '("live-foo" "saved-bar")
                 (decknix-picker-selections-coerce
                  '(multi-category "live-foo" "saved-bar")))))

(ert-deftest decknix-picker-selections--propertized-cands-preserved ()
  "Text properties on candidates pass through untouched -- hash lookup uses `equal'
which ignores properties, but the coercer must not strip them in case other
consumers care."
  (let* ((raw "session-foo")
         (cand (copy-sequence raw)))
    (add-text-properties 0 (length cand) '(face consult-buffer) cand)
    (let ((result (decknix-picker-selections-coerce
                   (list 'agent-session-saved cand))))
      (should (equal result (list cand)))
      ;; The face property must survive the coerce.
      (should (eq 'consult-buffer
                  (get-text-property 0 'face (car result)))))))

(ert-deftest decknix-picker-selections--defensive-flat-list-passthrough ()
  "Defensive: if a future embark returns a bare list of strings (no leading
symbol), pass through unchanged so dispatch still sees usable candidates."
  (should (equal '("a" "b")
                 (decknix-picker-selections-coerce '("a" "b")))))

(ert-deftest decknix-picker-selections--length-matches-cand-count ()
  "Regression: `(length (coerce ...))' must equal the number of marked items
-- the prior bug counted TYPE as an item, giving a 1-off result the picker
used to gate multi-mode."
  (should (= 2
             (length (decknix-picker-selections-coerce
                      '(agent-session-saved "a" "b"))))))

;; == decknix-picker-selections-cand-key ==
;;
;; consult--multi candidates arrive with a trailing `consult-strip'
;; character and a `multi-category' text property whose cdr is the
;; canonical display key the source's :items lambda used as its
;; hash-table key.  The picker dispatch must look maps up by that
;; canonical key, not by the propertized 161-char candidate string,
;; or every `gethash' silently misses and RET no-ops on the user.

(ert-deftest decknix-picker-selections-cand-key--plain-string ()
  "A bare string with no `multi-category' property maps to itself."
  (should (equal "session-foo"
                 (decknix-picker-selections-cand-key "session-foo"))))

(ert-deftest decknix-picker-selections-cand-key--multi-category-property ()
  "When the candidate carries a `multi-category' (TYPE . KEY) property,
the helper returns KEY -- the canonical hash key the source built."
  (let* ((key "059df5e8  display string")
         (cand (concat key (propertize " " 'invisible t 'consult-strip t))))
    (add-text-properties 0 (length key)
                         (list 'multi-category (cons 'agent-session-saved key))
                         cand)
    (should (equal key (decknix-picker-selections-cand-key cand)))))

(ert-deftest decknix-picker-selections-cand-key--non-string-passthrough ()
  "Defensive: a non-string candidate is returned unchanged so callers
that already hold a payload (e.g. an alist) don't crash."
  (let ((alist '((firstUserMessage . "hi"))))
    (should (eq alist (decknix-picker-selections-cand-key alist)))))

(ert-deftest decknix-picker-selections-cand-key--malformed-property-fallback ()
  "If `multi-category' is present but not a (SYMBOL . STRING) cons,
the helper falls back to the candidate string itself."
  (let ((cand (copy-sequence "session-foo")))
    (add-text-properties 0 (length cand)
                         '(multi-category agent-session-saved)
                         cand)
    (should (equal cand (decknix-picker-selections-cand-key cand)))))

(provide 'decknix-picker-selections-test)
;;; decknix-picker-selections-test.el ends here
