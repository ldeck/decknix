;;; decknix-session-assoc-test.el --- Observed session association -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Two properties carry this feature, and both come from measuring a live
;; session rather than from reasoning about it.
;;
;; Longest-match resolution: the session had edited files in worktrees under
;; `platform-cli-worktrees/', and a plain prefix test attributes those to
;; `platform-cli', collapsing every worktree of a repo into the repo.  That
;; defeats the point of being worktree-granular.
;;
;; The recency bound: the same session had touched 39 worktrees across four
;; repos over two months, and 2 within its last 20 turns.  Unbounded
;; observation is as useless as the wrong single repo the tag named.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-session-assoc)

;; Declared WITH a value so `let' below binds it dynamically.  A
;; one-argument `defvar' (which is what the module under test uses) marks a
;; variable special only within its own file, so in this `lexical-binding'
;; test file a bare `let' created a lexical binding instead -- and the code
;; under test, which guards with `boundp', correctly saw nothing.
(defvar decknix--hub-wt-facts nil)
(defvar decknix--agent-assoc-store nil)
(defvar decknix--agent-broker-key nil)

(defconst dk-assoc-test--roots
  '("/w/platform-cli"
    "/w/platform-cli-worktrees/CONN-1040"
    "/w/platform-cli-worktrees/CONN-1078"
    "/w/rea-integration"
    "/w/rea-integration-worktrees/CONN-801"))

;; --- path resolution --------------------------------------------------

(ert-deftest dk-assoc--longest-root-wins ()
  "A file in a worktree must attribute to the WORKTREE, not to the repo
checkout whose path is also a prefix of it."
  (should (equal "/w/platform-cli-worktrees/CONN-1040"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli-worktrees/CONN-1040/cmd/platform/x.go"
                  dk-assoc-test--roots))))

(ert-deftest dk-assoc--the-repo-itself-still-resolves ()
  (should (equal "/w/platform-cli"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli/cmd/platform/x.go" dk-assoc-test--roots))))

(ert-deftest dk-assoc--order-of-roots-does-not-decide ()
  "A plain prefix test returns whichever came first; the result must not
depend on the audit's ordering."
  (let ((a (decknix-session-assoc-resolve
            "/w/platform-cli-worktrees/CONN-1078/f.go" dk-assoc-test--roots))
        (b (decknix-session-assoc-resolve
            "/w/platform-cli-worktrees/CONN-1078/f.go"
            (reverse dk-assoc-test--roots))))
    (should (equal a b))
    (should (equal "/w/platform-cli-worktrees/CONN-1078" a))))

(ert-deftest dk-assoc--a-path-outside-every-root-is-nil ()
  (should-not (decknix-session-assoc-resolve "/tmp/scratch/x.go"
                                             dk-assoc-test--roots)))

(ert-deftest dk-assoc--a-known-worktree-always-beats-its-repo ()
  "Directories are compared, not string prefixes, so the repo never wins
over a worktree the audit knows about."
  (should (equal "/w/platform-cli-worktrees/CONN-1040"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli-worktrees/CONN-1040/x.go"
                  '("/w/platform-cli" "/w/platform-cli-worktrees/CONN-1040")))))

(ert-deftest dk-assoc--a-removed-worktree-falls-back-to-its-repo ()
  "Once work merges the worktree is removed, so its paths match no root and
a session whose recent work was there resolved to NOTHING.  Measured: the
session this was built for last worked in a platform-cli worktree since
deleted.  The repo outlives it and still carries the PRs."
  (should (equal "/w/platform-cli"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli-worktrees/CONN-1040/x.go"
                  '("/w/platform-cli")))))

(ert-deftest dk-assoc--the-fallback-needs-the-repo-to-be-known ()
  "Deriving a repo from the path is a convention, not evidence it exists."
  (should-not (decknix-session-assoc-resolve
               "/w/platform-cli-worktrees/CONN-1040/x.go"
               '("/w/something-else"))))

(ert-deftest dk-assoc--the-fallback-only-applies-to-worktree-paths ()
  "A path outside the `-worktrees' convention must not acquire a repo."
  (should-not (decknix-session-assoc-resolve
               "/w/platform-cli-scratch/x.go" '("/w/platform-cli"))))

(ert-deftest dk-assoc--no-roots-is-nil-not-an-error ()
  (should-not (decknix-session-assoc-resolve "/w/x/y.go" nil)))

;; --- reading paths off an update --------------------------------------

(ert-deftest dk-assoc--paths-come-from-locations ()
  (should (equal '("/a/b.go" "/c/d.go")
                 (decknix-session-assoc-paths-of
                  '((sessionUpdate . "tool_call")
                    (locations . (((path . "/a/b.go")) ((path . "/c/d.go")))))))))

(ert-deftest dk-assoc--an-update-with-no-locations-yields-nothing ()
  "Most updates are message chunks; this runs on every one of them."
  (should-not (decknix-session-assoc-paths-of
               '((sessionUpdate . "agent_message_chunk")))))

(ert-deftest dk-assoc--a-location-with-no-path-is-skipped ()
  (should (equal '("/a/b.go")
                 (decknix-session-assoc-paths-of
                  '((locations . (((path . "/a/b.go")) ((line . 3)))))))))

;; --- the recency-bounded set ------------------------------------------

(ert-deftest dk-assoc--only-the-latest-turn-per-root-is-kept ()
  "Keeping every touch would grow without bound in exactly the long-lived
sessions this exists to handle -- 1435 path events on the one measured."
  (let ((a (decknix-session-assoc-touch nil "/w/x" 1)))
    (setq a (decknix-session-assoc-touch a "/w/x" 7))
    (should (= 1 (length a)))
    (should (= 7 (cdr (car a))))))

(ert-deftest dk-assoc--active-drops-roots-outside-the-window ()
  "The measured session had touched 39 worktrees over two months and 2 in
its last 20 turns."
  (let ((a (decknix-session-assoc-touch
            (decknix-session-assoc-touch nil "/w/old" 10) "/w/new" 100)))
    (should (equal '("/w/new") (decknix-session-assoc-active a 100 20)))))

(ert-deftest dk-assoc--active-is-most-recent-first ()
  "The work in hand belongs at the top of a session's subtree."
  (let ((a (decknix-session-assoc-touch
            (decknix-session-assoc-touch nil "/w/older" 95) "/w/newer" 99)))
    (should (equal '("/w/newer" "/w/older")
                   (decknix-session-assoc-active a 100 20)))))

(ert-deftest dk-assoc--a-root-touched-this-turn-is-active ()
  (let ((a (decknix-session-assoc-touch nil "/w/x" 100)))
    (should (equal '("/w/x") (decknix-session-assoc-active a 100 20)))))

(ert-deftest dk-assoc--prune-bounds-what-is-persisted ()
  "One root per turn for 50 turns; pruning at the latest of them keeps
exactly the window.  Without this, a session's stored association grows
to the 39 entries the full history produced."
  (let ((a nil))
    (dotimes (i 50) (setq a (decknix-session-assoc-touch a (format "/w/%d" i) i)))
    (should (= 50 (length a)))
    ;; Turns run 0..49, so "now" is 49: a window of 20 keeps 30..49.
    (should (= 20 (length (decknix-session-assoc-prune a 49 20))))))

(ert-deftest dk-assoc--touching-nil-changes-nothing ()
  "A path outside every known root resolves to nil, and that must not
record an entry."
  (let ((a (decknix-session-assoc-touch nil "/w/x" 1)))
    (should (equal a (decknix-session-assoc-touch a nil 2)))))

;; --- claims -----------------------------------------------------------

(ert-deftest dk-assoc--claims-a-worktree-it-is-working-in ()
  (should (decknix-session-assoc-claims-wt-p
           '("/w/platform-cli-worktrees/CONN-1040") "/w/platform-cli-worktrees/CONN-1040")))

(ert-deftest dk-assoc--trailing-slashes-do-not-break-the-claim ()
  "The audit writes some paths with a trailing slash and some without --
the normalisation bug that once hid `decknix-config' from the picker."
  (should (decknix-session-assoc-claims-wt-p
           '("/w/a/") "/w/a"))
  (should (decknix-session-assoc-claims-wt-p
           '("/w/a") "/w/a/")))

(ert-deftest dk-assoc--does-not-claim-an-untouched-worktree ()
  "The failure the tag rule had: claiming work the session never touched."
  (should-not (decknix-session-assoc-claims-wt-p
               '("/w/platform-cli-worktrees/CONN-1040")
               "/w/platform-cli-worktrees/CONN-1078")))

(ert-deftest dk-assoc--claims-a-pr-by-the-branch-of-a-worktree-it-touched ()
  "A PR is claimed by branch, which is precise, rather than by repo,
which is what let one session's tag claim another's PRs."
  (let ((branches '(("/w/wt-a" . "CONN-1040-fix") ("/w/wt-b" . "other"))))
    (should (decknix-session-assoc-claims-branch-p
             '("/w/wt-a") "CONN-1040-fix"
             (lambda (r) (alist-get r branches nil nil #'equal))))
    (should-not (decknix-session-assoc-claims-branch-p
                 '("/w/wt-a") "other"
                 (lambda (r) (alist-get r branches nil nil #'equal))))))

(ert-deftest dk-assoc--a-session-spanning-repos-claims-in-both ()
  "The case that prompted this: one session working in platform-cli AND
rea-integration worktrees, which a repo-granular rule cannot express."
  (let ((roots '("/w/platform-cli-worktrees/CONN-1040"
                 "/w/rea-integration-worktrees/CONN-801")))
    (should (decknix-session-assoc-claims-wt-p roots "/w/platform-cli-worktrees/CONN-1040"))
    (should (decknix-session-assoc-claims-wt-p roots "/w/rea-integration-worktrees/CONN-801"))))


;; --- capture ----------------------------------------------------------

(ert-deftest dk-assoc--capture-records-the-resolved-worktree ()
  (let ((buf (generate-new-buffer " cap")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'decknix-session-assoc-roots)
                     (lambda () '("/w/platform-cli-worktrees/CONN-1040"))))
            (should (decknix-session-assoc-observe
                     '((sessionUpdate . "tool_call")
                       (locations . (((path . "/w/platform-cli-worktrees/CONN-1040/x.go")))))))
            (should (equal '("/w/platform-cli-worktrees/CONN-1040")
                           (decknix-session-assoc-current buf)))))
      (kill-buffer buf))))

(ert-deftest dk-assoc--capture-ignores-an-update-with-no-locations ()
  "This runs on EVERY streamed chunk -- 24707 message chunks against 2400
tool calls on the measured session -- so the common case must do nothing."
  (let ((buf (generate-new-buffer " cap2")) (roots-called 0))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'decknix-session-assoc-roots)
                     (lambda () (setq roots-called (1+ roots-called)) nil)))
            (should-not (decknix-session-assoc-observe
                         '((sessionUpdate . "agent_message_chunk"))))
            ;; Not even the roots lookup may be reached.
            (should (= 0 roots-called))))
      (kill-buffer buf))))

(ert-deftest dk-assoc--capture-ignores-a-path-outside-every-root ()
  (let ((buf (generate-new-buffer " cap3")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'decknix-session-assoc-roots)
                     (lambda () '("/w/known"))))
            (should-not (decknix-session-assoc-observe
                         '((locations . (((path . "/tmp/elsewhere/x.go")))))))
            (should-not (decknix-session-assoc-current buf))))
      (kill-buffer buf))))

(ert-deftest dk-assoc--ending-a-turn-advances-the-recency-clock ()
  "Without this the window never moves and association never decays."
  (let ((buf (generate-new-buffer " cap4")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'decknix-session-assoc-roots)
                     (lambda () '("/w/a"))))
            (decknix-session-assoc-observe
             '((locations . (((path . "/w/a/x.go"))))))
            (should (equal '("/w/a") (decknix-session-assoc-current buf)))
            ;; Push the touch outside the window.
            (dotimes (_ (1+ decknix-session-assoc-window))
              (decknix-session-assoc-end-turn))
            (should-not (decknix-session-assoc-current buf))))
      (kill-buffer buf))))

(ert-deftest dk-assoc--a-session-that-never-captured-has-no-association ()
  "Must be nil rather than an error: every session is asked, including
ones that have run no tool calls at all."
  (let ((buf (generate-new-buffer " cap5")))
    (unwind-protect
        (should-not (decknix-session-assoc-current buf))
      (kill-buffer buf))))

(ert-deftest dk-assoc--roots-are-not-rederived-per-call ()
  "`decknix-hub-wt-rows' walks a hash table and allocates; calling it per
tool call is the shape of defect that has already cost three performance
regressions here."
  (let ((builds 0)
        (decknix--agent-assoc-roots-cache nil)
        (decknix--hub-wt-facts (make-hash-table :test 'equal)))
    (puthash "/w/a" '((path . "/w/a")) decknix--hub-wt-facts)
    (cl-letf (((symbol-function 'decknix-hub-wt-rows)
               (lambda () (setq builds (1+ builds)) '(((path . "/w/a"))))))
      (dotimes (_ 50) (decknix-session-assoc-roots))
      (should (= 1 builds)))))

(ert-deftest dk-assoc--roots-rebuild-when-the-worktree-table-changes ()
  (let ((builds 0)
        (decknix--agent-assoc-roots-cache nil)
        (decknix--hub-wt-facts (make-hash-table :test 'equal)))
    (puthash "/w/a" '((path . "/w/a")) decknix--hub-wt-facts)
    (cl-letf (((symbol-function 'decknix-hub-wt-rows)
               (lambda () (setq builds (1+ builds)) '(((path . "/w/a"))))))
      (decknix-session-assoc-roots)
      (puthash "/w/b" '((path . "/w/b")) decknix--hub-wt-facts)
      (decknix-session-assoc-roots)
      (should (= 2 builds)))))


;; --- real JSON shapes -------------------------------------------------

(ert-deftest dk-assoc--locations-may-be-a-vector ()
  "`json-parse-string' renders a JSON array as a VECTOR, so a `listp'
test discarded every path.  Hand-written list fixtures passed while a
real 76 MB log yielded nothing at all -- found only by running the
backfill against one."
  (should (equal '("/a/b.go")
                 (decknix-session-assoc-paths-of
                  '((locations . [((path . "/a/b.go"))]))))))

(ert-deftest dk-assoc--a-vector-of-several-locations-is-read-whole ()
  (should (equal '("/a.go" "/b.go")
                 (decknix-session-assoc-paths-of
                  '((locations . [((path . "/a.go")) ((path . "/b.go"))]))))))

;; --- backfill from log lines ------------------------------------------

(ert-deftest dk-assoc--backfill-counts-turns-and-records-roots ()
  (let* ((lines (list
                 "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"locations\":[{\"path\":\"/w/a/x.go\"}]}}}"
                 "{\"id\":1,\"result\":{\"stopReason\":\"end_turn\"}}"
                 "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"locations\":[{\"path\":\"/w/b/y.go\"}]}}}"))
         (res (decknix-session-assoc-from-lines lines '("/w/a" "/w/b"))))
    (should (= 1 (car res)))
    (should (equal '("/w/b" "/w/a")
                   (decknix-session-assoc-active (cdr res) (car res) 20)))))

(ert-deftest dk-assoc--backfill-ignores-paths-outside-known-roots ()
  "A log is full of /tmp scratch files; the first real sample found was
`/tmp/nix-pipeline-architecture.dot'."
  (let* ((lines (list
                 "{\"method\":\"session/update\",\"params\":{\"update\":{\"locations\":[{\"path\":\"/tmp/scratch.dot\"}]}}}"))
         (res (decknix-session-assoc-from-lines lines '("/w/a"))))
    (should-not (cdr res))))

(ert-deftest dk-assoc--backfill-of-empty-lines-is-turn-zero ()
  (should (equal '(0) (decknix-session-assoc-from-lines nil '("/w/a")))))

(ert-deftest dk-assoc--backfill-tolerates-a-torn-line ()
  "A bounded tail starts mid-line by construction."
  (let ((res (decknix-session-assoc-from-lines
              (list "ions\":[{\"path\":\"/w/a/x.go\"}]}}}"
                    "{\"method\":\"session/update\",\"params\":{\"update\":{\"locations\":[{\"path\":\"/w/a/y.go\"}]}}}")
              '("/w/a"))))
    (should (equal '("/w/a") (decknix-session-assoc-active (cdr res) (car res) 20)))))

;; --- persistence ------------------------------------------------------

(ert-deftest dk-assoc--store-round-trips ()
  (let* ((tmp (make-temp-file "dk-assoc" nil ".eld"))
         (decknix--agent-assoc-store nil))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-session-assoc-state-file)
                   (lambda () tmp)))
          (decknix-session-assoc-remember "s-k" 7 '(("/w/a" . 7)))
          (setq decknix--agent-assoc-store nil)
          (decknix-session-assoc-load)
          (should (equal '(7 ("/w/a" . 7)) (decknix-session-assoc-recall "s-k"))))
      (delete-file tmp))))

(ert-deftest dk-assoc--remember-replaces-rather-than-appends ()
  "Appending would grow the store without bound across turns -- 360 turns
on the session measured."
  (let* ((tmp (make-temp-file "dk-assoc2" nil ".eld"))
         (decknix--agent-assoc-store nil))
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-session-assoc-state-file)
                   (lambda () tmp)))
          (decknix-session-assoc-remember "s-k" 1 '(("/w/a" . 1)))
          (decknix-session-assoc-remember "s-k" 2 '(("/w/a" . 2)))
          (should (= 1 (length decknix--agent-assoc-store)))
          (should (equal 2 (car (decknix-session-assoc-recall "s-k")))))
      (delete-file tmp))))

(ert-deftest dk-assoc--restore-seeds-a-reattached-session ()
  "The point: a resumed session shows its worktrees immediately instead of
nothing until its next tool call."
  (let* ((buf (generate-new-buffer " rst"))
         (decknix--agent-assoc-store '(("s-k" . (9 ("/w/a" . 9))))))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq-local decknix--agent-broker-key "s-k"))
          (should (decknix-session-assoc-restore buf))
          (should (equal '("/w/a") (decknix-session-assoc-current buf))))
      (kill-buffer buf))))

(ert-deftest dk-assoc--restore-of-an-unknown-session-is-nil ()
  (let* ((buf (generate-new-buffer " rst2"))
         (decknix--agent-assoc-store nil))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq-local decknix--agent-broker-key "s-nope"))
          (should-not (decknix-session-assoc-restore buf)))
      (kill-buffer buf))))

(ert-deftest dk-assoc--restore-without-a-broker-key-is-nil ()
  (let ((buf (generate-new-buffer " rst3")))
    (unwind-protect (should-not (decknix-session-assoc-restore buf))
      (kill-buffer buf))))


;; --- launching from a row ---------------------------------------------

(ert-deftest dk-assoc--worktree-suggests-repo-and-ticket ()
  "How these sessions are tagged by hand anyway."
  (should (equal '("platform-cli" "CONN-1040")
                 (decknix-session-assoc-suggest-tags
                  "/w/platform-cli-worktrees/CONN-1040-generator-fixes"))))

(ert-deftest dk-assoc--a-plain-repo-suggests-just-its-name ()
  (should (equal '("rea-integration")
                 (decknix-session-assoc-suggest-tags "/w/rea-integration"))))

(ert-deftest dk-assoc--the-branch-supplies-the-ticket-when-the-dir-does-not ()
  (should (equal '("platform-cli" "CONN-9")
                 (decknix-session-assoc-suggest-tags
                  "/w/platform-cli-worktrees/scratch" "CONN-9-thing"))))

(ert-deftest dk-assoc--a-worktree-with-no-ticket-suggests-the-repo-only ()
  (should (equal '("platform-cli")
                 (decknix-session-assoc-suggest-tags
                  "/w/platform-cli-worktrees/nix-jvm-privategar"))))

(ert-deftest dk-assoc--a-trailing-slash-does-not-change-the-suggestion ()
  "The worktree audit writes paths both ways."
  (should (equal (decknix-session-assoc-suggest-tags "/w/platform-cli-worktrees/CONN-1040")
                 (decknix-session-assoc-suggest-tags "/w/platform-cli-worktrees/CONN-1040/"))))

(ert-deftest dk-assoc--launch-target-carries-path-and-tags ()
  (let ((target (decknix-session-assoc-launch-target
                 '(:path "/w/platform-cli-worktrees/CONN-1040" :branch "CONN-1040-x"))))
    (should (equal "/w/platform-cli-worktrees/CONN-1040" (car target)))
    (should (member "platform-cli" (cdr target)))))

(ert-deftest dk-assoc--a-row-with-no-path-cannot-be-launched ()
  "A session has to start somewhere; refusing is better than defaulting
to whatever directory happened to be current."
  (should-not (decknix-session-assoc-launch-target '(:branch "x")))
  (should-not (decknix-session-assoc-launch-target '(:path ""))))

(provide 'decknix-session-assoc-test)
;;; decknix-session-assoc-test.el ends here
