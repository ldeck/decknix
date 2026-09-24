;;; decknix-agent-tags-read-test.el --- Tests for tags read accessors -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-tags-read "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the two tags read accessors.
;; The tests stub `decknix--agent-tags-read' /
;; `-tags-conversations' against an in-memory hash; the
;; session-id variant additionally stubs
;; `decknix--agent-conversation-key-for-session' so the resolve
;; step is decoupled from the session-cache layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-tags-read)

;; -- Test fixtures -----------------------------------------------

(defvar decknix-test-tags-read--store nil
  "In-memory stand-in for the agent-sessions.json store.")

(defvar decknix-test-tags-read--session-to-conv nil
  "Alist mapping session-id -> conv-key for the resolver stub.")

(defun decknix-test-tags-read--fresh-store ()
  "Build an empty store hash matching the on-disk shape."
  (let ((root (make-hash-table :test 'equal))
        (convs (make-hash-table :test 'equal)))
    (puthash "conversations" convs root)
    root))

(defmacro decknix-test-tags-read-with-store (&rest body)
  "Run BODY with an isolated in-memory store stubbing accessors + resolver."
  (declare (indent 0))
  `(let ((decknix-test-tags-read--store
          (decknix-test-tags-read--fresh-store))
         (decknix-test-tags-read--session-to-conv nil))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () decknix-test-tags-read--store))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (store) (gethash "conversations" store)))
               ((symbol-function 'decknix--agent-conversation-key-for-session)
                (lambda (sid &optional _no-block)
                  (cdr (assoc sid decknix-test-tags-read--session-to-conv)))))
       ,@body)))

(defun decknix-test-tags-read--seed (conv-key &rest plist)
  "Insert an entry for CONV-KEY built from PLIST (k1 v1 k2 v2 ...)."
  (let ((entry (make-hash-table :test 'equal)))
    (cl-loop for (k v) on plist by #'cddr do
             (puthash k v entry))
    (puthash conv-key entry
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))))

;; -- tags-for-conv-key (direct) ----------------------------------

(ert-deftest decknix-agent-tags-read--ck-missing-returns-nil ()
  "Direct reader returns nil when CONV-KEY has no entry."
  (decknix-test-tags-read-with-store
    (should (null (decknix--agent-tags-for-conv-key "missing")))))

(ert-deftest decknix-agent-tags-read--ck-entry-without-tags-returns-nil ()
  "Direct reader returns nil when entry exists but has no `tags' field."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "workspace" "/p")
    (should (null (decknix--agent-tags-for-conv-key "ck")))))

(ert-deftest decknix-agent-tags-read--ck-non-hash-entry-returns-nil ()
  "Direct reader returns nil when the entry is not a hash-table.
Defensive guard for legacy / corrupt entries."
  (decknix-test-tags-read-with-store
    (puthash "ck" '(:not-a-hash)
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))
    (should (null (decknix--agent-tags-for-conv-key "ck")))))

(ert-deftest decknix-agent-tags-read--ck-returns-stored-tags ()
  "Direct reader returns the stored tags list verbatim."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "tags" '("review" "backend"))
    (should (equal '("review" "backend")
                   (decknix--agent-tags-for-conv-key "ck")))))

;; -- tags-for-session (resolved) ---------------------------------

(ert-deftest decknix-agent-tags-read--sid-unresolved-returns-nil ()
  "Session reader returns nil when resolver returns nil."
  (decknix-test-tags-read-with-store
    (should (null (decknix--agent-tags-for-session "unknown-sid")))))

(ert-deftest decknix-agent-tags-read--sid-resolved-no-entry-returns-nil ()
  "Session reader returns nil when conv-key resolves but no entry exists."
  (decknix-test-tags-read-with-store
    (push '("sid-1" . "ck-1") decknix-test-tags-read--session-to-conv)
    (should (null (decknix--agent-tags-for-session "sid-1")))))

(ert-deftest decknix-agent-tags-read--sid-resolved-no-tags-returns-nil ()
  "Session reader returns nil when entry exists but has no `tags' field."
  (decknix-test-tags-read-with-store
    (push '("sid-1" . "ck-1") decknix-test-tags-read--session-to-conv)
    (decknix-test-tags-read--seed "ck-1" "workspace" "/p")
    (should (null (decknix--agent-tags-for-session "sid-1")))))

(ert-deftest decknix-agent-tags-read--sid-returns-stored-tags ()
  "Session reader returns tags via resolver -> entry lookup."
  (decknix-test-tags-read-with-store
    (push '("sid-1" . "ck-1") decknix-test-tags-read--session-to-conv)
    (decknix-test-tags-read--seed "ck-1" "tags" '("frontend"))
    (should (equal '("frontend")
                   (decknix--agent-tags-for-session "sid-1")))))

;; -- tags-all (aggregation) --------------------------------------

(ert-deftest decknix-agent-tags-read--all-empty-store ()
  "Aggregate returns nil when no conversations exist."
  (decknix-test-tags-read-with-store
    (should (null (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-no-tags ()
  "Aggregate returns nil when conversations exist but none carry tags."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "workspace" "/p")
    (decknix-test-tags-read--seed "ck-2" "workspace" "/q")
    (should (null (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-deduplicates ()
  "Aggregate dedupes tags shared across conversations."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "tags" '("review" "backend"))
    (decknix-test-tags-read--seed "ck-2" "tags" '("backend" "infra"))
    (should (equal '("backend" "infra" "review")
                   (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-sorts-string-lt ()
  "Aggregate returns tags sorted by `string<'."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "tags" '("zeta" "alpha" "mu"))
    (should (equal '("alpha" "mu" "zeta")
                   (decknix--agent-tags-all)))))

(ert-deftest decknix-agent-tags-read--all-skips-non-hash-entries ()
  "Aggregate is defensive against legacy / corrupt non-hash entries."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck-1" "tags" '("real"))
    (puthash "ck-2" '(:not-a-hash)
             (decknix--agent-tags-conversations
              (decknix--agent-tags-read)))
    (should (equal '("real") (decknix--agent-tags-all)))))

;; --- the buffer-level resolver -----------------------------------------
;;
;; `decknix--agent-tags-resolve' was added so every consumer could fall back
;; from a divergent conv-key to the stable session id.  It was then wired
;; into ONE consumer.  Twenty-five others still ask the conv-key alone, and
;; the reason is structural rather than an oversight: most of them hold a
;; BUFFER, not a (conv-key, session-id) pair, so calling the resolver meant
;; each site digging both out for itself.
;;
;; Session 5de16692 is what that costs.  Its buffer's conv-key
;; (523fdb64f335b839) is real but untagged, while the tags -- guidelines,
;; policies, ai, nurturecloud -- sit under a sibling entry keyed by session
;; id.  So the buffer named itself after its workspace, `*Claude:
;; nurturecloud*', and the sidebar row showed no tags: unrecognisable among
;; a dozen sessions.
;;
;; One buffer-level entry point removes the excuse.

(ert-deftest decknix-tags-buffer--prefers-the-conv-key ()
  "When the conv-key has tags, they win and no session lookup is needed."
  (cl-letf (((symbol-function 'decknix--agent-current-conv-key) (lambda () "ck"))
            ((symbol-function 'decknix--agent-current-session-id) (lambda () "sid"))
            ((symbol-function 'decknix--agent-tags-for-conv-key)
             (lambda (k) (when (equal k "ck") '("from-conv"))))
            ((symbol-function 'decknix--agent-tags-for-session)
             (lambda (_s) nil)))
    (with-temp-buffer
      (should (equal '("from-conv") (decknix--agent-tags-for-buffer (current-buffer)))))))

(ert-deftest decknix-tags-buffer--falls-back-to-the-session-id ()
  "The 5de16692 shape: a real but untagged conv-key, tags under the sid."
  (cl-letf (((symbol-function 'decknix--agent-current-conv-key) (lambda () "523fdb64f335b839"))
            ((symbol-function 'decknix--agent-current-session-id) (lambda () "5de16692"))
            ((symbol-function 'decknix--agent-tags-for-conv-key) (lambda (_k) nil))
            ;; `tags-resolve\=' now reaches the store scan directly rather
            ;; than via `tags-for-session\=', which used to cost a session-list
            ;; round trip on every call.  Same fallback, cheaper mechanism.
            ((symbol-function 'decknix--agent-tags-read) (lambda () nil))
            ((symbol-function 'decknix--agent-tags-conversations) (lambda (_s) nil))
            ((symbol-function 'decknix--agent-store-field-scan)
             (lambda (_c _s _f) '("guidelines" "policies" "ai" "nurturecloud"))))
    (with-temp-buffer
      (should (equal '("guidelines" "policies" "ai" "nurturecloud")
                     (decknix--agent-tags-for-buffer (current-buffer)))))))

(ert-deftest decknix-tags-buffer--unions-when-both-answer ()
  "A resume can split tags across entries; neither alone is the answer."
  (cl-letf (((symbol-function 'decknix--agent-current-conv-key) (lambda () "ck"))
            ((symbol-function 'decknix--agent-current-session-id) (lambda () "sid"))
            ((symbol-function 'decknix--agent-tags-for-conv-key) (lambda (_k) '("a" "b")))
            ((symbol-function 'decknix--agent-tags-read) (lambda () nil))
            ((symbol-function 'decknix--agent-tags-conversations) (lambda (_s) nil))
            ((symbol-function 'decknix--agent-store-field-scan)
             (lambda (_c _s _f) '("b" "c"))))
    (with-temp-buffer
      (should (equal '("a" "b" "c") (decknix--agent-tags-for-buffer (current-buffer)))))))

(ert-deftest decknix-tags-buffer--nil-when-neither-answers ()
  "An untagged session stays untagged; no invented tags."
  (cl-letf (((symbol-function 'decknix--agent-current-conv-key) (lambda () "ck"))
            ((symbol-function 'decknix--agent-current-session-id) (lambda () "sid"))
            ((symbol-function 'decknix--agent-tags-for-conv-key) (lambda (_k) nil))
            ((symbol-function 'decknix--agent-tags-for-session) (lambda (_s) nil)))
    (with-temp-buffer
      (should-not (decknix--agent-tags-for-buffer (current-buffer))))))

(ert-deftest decknix-tags-buffer--tolerates-a-dead-or-nil-buffer ()
  "Callers pass buffers from lists that can go stale mid-render."
  (should-not (decknix--agent-tags-for-buffer nil))
  (let ((b (generate-new-buffer " *gone*")))
    (kill-buffer b)
    (should-not (decknix--agent-tags-for-buffer b))))

;; -- sibling scan: the conv-key-only side of the resolver ----------
;;
;; `decknix--agent-tags-resolve' takes a (CONV-KEY SESSION-ID) pair, and
;; `decknix--agent-tags-for-buffer' covers consumers holding a buffer.
;; Neither helps a consumer holding ONLY a conv-key -- a progress payload,
;; a group header, a hub-only key with no live buffer -- so those kept
;; calling `decknix--agent-tags-for-conv-key' and kept the bug: that
;; accessor reads ONE entry, and the entry a conv-key names is often the
;; untagged fragment while the tags sit under a sibling.

(ert-deftest decknix-tags-siblings--follows-a-shared-session-to-the-tags ()
  "The untagged fragment finds its tagged sibling via a shared session id.

Shaped on 5de16692: conv-key 523fdb64f335b839 is real but untagged while
its tags sit under a sibling entry."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "523fdb64f335b839"
                                  "sessions" '("5de16692"))
    (decknix-test-tags-read--seed "sibling-key"
                                  "sessions" '("5de16692")
                                  "tags" '("guidelines" "policies"))
    (let ((got (decknix--agent-tags-scan-siblings
                (decknix--agent-tags-conversations
                 (decknix--agent-tags-read))
                "523fdb64f335b839")))
      (should (member "guidelines" got))
      (should (member "policies" got)))))

(ert-deftest decknix-tags-siblings--unions-rather-than-first-hit ()
  "Own tags and sibling tags both survive.
A resume can split tags across entries, so neither alone is the answer --
the same reason `decknix--agent-tags-resolve' unions."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "sessions" '("s1") "tags" '("own"))
    (decknix-test-tags-read--seed "other" "sessions" '("s1") "tags" '("far"))
    (let ((got (decknix--agent-tags-scan-siblings
                (decknix--agent-tags-conversations
                 (decknix--agent-tags-read))
                "ck")))
      (should (member "own" got))
      (should (member "far" got)))))

(ert-deftest decknix-tags-siblings--deduplicates ()
  "A tag present on both sides appears once."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "sessions" '("s1") "tags" '("dup"))
    (decknix-test-tags-read--seed "other" "sessions" '("s1") "tags" '("dup"))
    (should (equal '("dup")
                   (decknix--agent-tags-scan-siblings
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read))
                    "ck")))))

(ert-deftest decknix-tags-siblings--unrelated-entries-are-not-pulled-in ()
  "Only entries SHARING a session id count.
Unioning across unrelated conversations is the failure the store
consolidation had to undo, so it is pinned here."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "sessions" '("s1") "tags" '("mine"))
    (decknix-test-tags-read--seed "stranger" "sessions" '("s9") "tags" '("theirs"))
    (let ((got (decknix--agent-tags-scan-siblings
                (decknix--agent-tags-conversations
                 (decknix--agent-tags-read))
                "ck")))
      (should (member "mine" got))
      (should-not (member "theirs" got)))))

(ert-deftest decknix-tags-siblings--degenerate-input-is-nil ()
  "A missing key, absent store or entry without sessions yields nil."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "tags" '("only-own"))
    (should-not (decknix--agent-tags-scan-siblings nil "ck"))
    (should-not (decknix--agent-tags-scan-siblings
                 (decknix--agent-tags-conversations
                  (decknix--agent-tags-read))
                 nil))
    ;; No `sessions' list: own tags still returned, no scan to do.
    (should (equal '("only-own")
                   (decknix--agent-tags-scan-siblings
                    (decknix--agent-tags-conversations
                     (decknix--agent-tags-read))
                    "ck")))))

(ert-deftest decknix-tags-for-conv-key-resolved--reads-the-store ()
  "The wrapper resolves through the live store."
  (decknix-test-tags-read-with-store
    (decknix-test-tags-read--seed "ck" "sessions" '("s1"))
    (decknix-test-tags-read--seed "sib" "sessions" '("s1") "tags" '("found"))
    (should (equal '("found") (decknix--agent-tags-for-conv-key-resolved "ck")))
    (should-not (decknix--agent-tags-for-conv-key-resolved nil))))


;; -- naming must re-run when tags first resolve --------------------
;;
;; Naming happens at shell creation, when a resumed session often has no
;; resolvable tags yet: its session id has not joined the conversation's
;; session set, so naming falls through to the workspace fallback.
;; Nothing re-ran it, so 5de16692 stayed `*Claude: nurturecloud*' for the
;; life of the buffer while carrying four tags.

(ert-deftest decknix-name-stale--fires-when-no-tag-is-in-the-name ()
  "The 5de16692 shape: workspace-derived name, tags now resolvable."
  (should (decknix--agent-name-stale-for-tags-p
           "*Claude: nurturecloud*" '("guidelines" "policies"))))

(ert-deftest decknix-name-stale--quiet-once-a-tag-is-present ()
  "A name already built from tags must not be re-derived on every poll.
Renaming repeatedly would fight the user's own `decknix-agent-session-rename'."
  (should-not (decknix--agent-name-stale-for-tags-p
               "*Claude: guidelines/policies*" '("guidelines" "policies"))))

(ert-deftest decknix-name-stale--any-tag-suffices ()
  "Matching the FIRST tag is enough; the name need not carry them all.
Requiring all of them would rename on every tag edit."
  (should-not (decknix--agent-name-stale-for-tags-p
               "*Claude: guidelines*" '("guidelines" "policies" "ai"))))

(ert-deftest decknix-name-stale--no-tags-means-nothing-to-do ()
  "Without tags there is no better name available, so never fire."
  (should-not (decknix--agent-name-stale-for-tags-p "*Claude: ws*" nil))
  (should-not (decknix--agent-name-stale-for-tags-p "*Claude: ws*" '())))

(ert-deftest decknix-name-stale--tolerates-degenerate-input ()
  "Empty tag strings and a nil name must not signal on a render path."
  (should-not (decknix--agent-name-stale-for-tags-p nil '("a")))
  (should (decknix--agent-name-stale-for-tags-p "*Claude: ws*" '("" "real"))))


(provide 'decknix-agent-tags-read-test)
;;; decknix-agent-tags-read-test.el ends here
