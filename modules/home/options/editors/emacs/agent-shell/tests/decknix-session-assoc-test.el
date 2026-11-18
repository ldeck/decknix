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
(defvar decknix--agent-conv-key nil)
(declare-function agent-shell-buffers "agent-shell" ())

(defconst dk-assoc-test--roots
  '("/w/platform-cli"
    "/w/platform-cli-worktrees/ACME-1040"
    "/w/platform-cli-worktrees/ACME-1078"
    "/w/web-integration"
    "/w/web-integration-worktrees/ACME-801"))

;; --- path resolution --------------------------------------------------

(ert-deftest dk-assoc--longest-root-wins ()
  "A file in a worktree must attribute to the WORKTREE, not to the repo
checkout whose path is also a prefix of it."
  (should (equal "/w/platform-cli-worktrees/ACME-1040"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli-worktrees/ACME-1040/cmd/platform/x.go"
                  dk-assoc-test--roots))))

(ert-deftest dk-assoc--the-repo-itself-still-resolves ()
  (should (equal "/w/platform-cli"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli/cmd/platform/x.go" dk-assoc-test--roots))))

(ert-deftest dk-assoc--order-of-roots-does-not-decide ()
  "A plain prefix test returns whichever came first; the result must not
depend on the audit's ordering."
  (let ((a (decknix-session-assoc-resolve
            "/w/platform-cli-worktrees/ACME-1078/f.go" dk-assoc-test--roots))
        (b (decknix-session-assoc-resolve
            "/w/platform-cli-worktrees/ACME-1078/f.go"
            (reverse dk-assoc-test--roots))))
    (should (equal a b))
    (should (equal "/w/platform-cli-worktrees/ACME-1078" a))))

(ert-deftest dk-assoc--a-path-outside-every-root-is-nil ()
  (should-not (decknix-session-assoc-resolve "/tmp/scratch/x.go"
                                             dk-assoc-test--roots)))

(ert-deftest dk-assoc--a-known-worktree-always-beats-its-repo ()
  "Directories are compared, not string prefixes, so the repo never wins
over a worktree the audit knows about."
  (should (equal "/w/platform-cli-worktrees/ACME-1040"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli-worktrees/ACME-1040/x.go"
                  '("/w/platform-cli" "/w/platform-cli-worktrees/ACME-1040")))))

(ert-deftest dk-assoc--a-removed-worktree-keeps-its-own-directory ()
  "Crediting the repo instead gave the session every PR and worktree in it."
  (should (equal "/w/platform-cli-worktrees/ACME-1040"
                 (decknix-session-assoc-resolve
                  "/w/platform-cli-worktrees/ACME-1040/x.go"
                  '("/w/platform-cli")))))

(ert-deftest dk-assoc--a-worktree-created-after-the-roots-is-still-itself ()
  "Same case from the other side: the root list predates the worktree."
  (should (equal "/w/gateway-worktrees/PLAT-1293-tenantb"
                 (decknix-session-assoc-resolve
                  "/w/gateway-worktrees/PLAT-1293-tenantb/src/main.go"
                  '("/w/gateway" "/w/widget")))))

(ert-deftest dk-assoc--the-fallback-needs-the-repo-to-be-known ()
  "Deriving a repo from the path is a convention, not evidence it exists."
  (should-not (decknix-session-assoc-resolve
               "/w/platform-cli-worktrees/ACME-1040/x.go"
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
           '("/w/platform-cli-worktrees/ACME-1040") "/w/platform-cli-worktrees/ACME-1040")))

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
               '("/w/platform-cli-worktrees/ACME-1040")
               "/w/platform-cli-worktrees/ACME-1078")))

(ert-deftest dk-assoc--claims-a-pr-by-the-branch-of-a-worktree-it-touched ()
  "A PR is claimed by branch, which is precise, rather than by repo,
which is what let one session's tag claim another's PRs."
  (let ((branches '(("/w/wt-a" . "ACME-1040-fix") ("/w/wt-b" . "other"))))
    (should (decknix-session-assoc-claims-branch-p
             '("/w/wt-a") "ACME-1040-fix"
             (lambda (r) (alist-get r branches nil nil #'equal))))
    (should-not (decknix-session-assoc-claims-branch-p
                 '("/w/wt-a") "other"
                 (lambda (r) (alist-get r branches nil nil #'equal))))))

(ert-deftest dk-assoc--a-session-spanning-repos-claims-in-both ()
  "The case that prompted this: one session working in platform-cli AND
web-integration worktrees, which a repo-granular rule cannot express."
  (let ((roots '("/w/platform-cli-worktrees/ACME-1040"
                 "/w/web-integration-worktrees/ACME-801")))
    (should (decknix-session-assoc-claims-wt-p roots "/w/platform-cli-worktrees/ACME-1040"))
    (should (decknix-session-assoc-claims-wt-p roots "/w/web-integration-worktrees/ACME-801"))))


;; --- capture ----------------------------------------------------------

(ert-deftest dk-assoc--capture-records-the-resolved-worktree ()
  (let ((buf (generate-new-buffer " cap")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'decknix-session-assoc-roots)
                     (lambda () '("/w/platform-cli-worktrees/ACME-1040"))))
            (should (decknix-session-assoc-observe
                     '((sessionUpdate . "tool_call")
                       (locations . (((path . "/w/platform-cli-worktrees/ACME-1040/x.go")))))))
            (should (equal '("/w/platform-cli-worktrees/ACME-1040")
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
  (should (equal '("platform-cli" "ACME-1040")
                 (decknix-session-assoc-suggest-tags
                  "/w/platform-cli-worktrees/ACME-1040-generator-fixes"))))

(ert-deftest dk-assoc--a-plain-repo-suggests-just-its-name ()
  (should (equal '("web-integration")
                 (decknix-session-assoc-suggest-tags "/w/web-integration"))))

(ert-deftest dk-assoc--the-branch-supplies-the-ticket-when-the-dir-does-not ()
  (should (equal '("platform-cli" "ACME-9")
                 (decknix-session-assoc-suggest-tags
                  "/w/platform-cli-worktrees/scratch" "ACME-9-thing"))))

(ert-deftest dk-assoc--a-worktree-with-no-ticket-suggests-the-repo-only ()
  (should (equal '("platform-cli")
                 (decknix-session-assoc-suggest-tags
                  "/w/platform-cli-worktrees/nix-jvm-privategar"))))

(ert-deftest dk-assoc--a-trailing-slash-does-not-change-the-suggestion ()
  "The worktree audit writes paths both ways."
  (should (equal (decknix-session-assoc-suggest-tags "/w/platform-cli-worktrees/ACME-1040")
                 (decknix-session-assoc-suggest-tags "/w/platform-cli-worktrees/ACME-1040/"))))

(ert-deftest dk-assoc--launch-target-carries-path-and-tags ()
  (let ((target (decknix-session-assoc-launch-target
                 '(:path "/w/platform-cli-worktrees/ACME-1040" :branch "ACME-1040-x"))))
    (should (equal "/w/platform-cli-worktrees/ACME-1040" (car target)))
    (should (member "platform-cli" (cdr target)))))

(ert-deftest dk-assoc--a-row-with-no-path-cannot-be-launched ()
  "A session has to start somewhere; refusing is better than defaulting
to whatever directory happened to be current."
  (should-not (decknix-session-assoc-launch-target '(:branch "x")))
  (should-not (decknix-session-assoc-launch-target '(:path ""))))

;; --- paths named only in a tool call's input --------------------------
;;
;; A session did all its infra-foundations work through subagent Bash calls:
;; 35 touches, `locations' null on every one, the path only in the command
;; text.  None was recorded and the PR it was shepherding showed Unattended.

(ert-deftest dk-assoc--a-bash-command-names-its-working-directory ()
  (should (equal '("/Users/me/w/hf-worktrees/ACME-1163-x")
                 (decknix-session-assoc-paths-of
                  '((kind . "execute")
                    (rawInput . ((command . "cd /Users/me/w/hf-worktrees/ACME-1163-x; git grep -n y | head"))))))))

(ert-deftest dk-assoc--input-paths-come-from-every-field ()
  (should (equal '("/Users/me/w/a.kt" "/Users/me/w/b")
                 (decknix-session-assoc-input-paths
                  '((file_path . "/Users/me/w/a.kt") (nested . [((cwd . "/Users/me/w/b"))]))))))

(ert-deftest dk-assoc--a-url-is-not-a-path ()
  (should-not (decknix-session-assoc-input-paths
               '((command . "gh pr view https://github.com/o/r/pull/1051")))))

(ert-deftest dk-assoc--a-path-ends-at-a-newline-whatever-the-syntax-table ()
  "`[:space:]' follows the current syntax table, where a newline can be a
comment ender rather than whitespace; the path then ran on to the next
line and resolved to a junk root."
  (with-syntax-table emacs-lisp-mode-syntax-table
    (should (equal '("/Users/me/w/a" "/Users/me/w/b")
                   (decknix-session-assoc-input-paths
                    '((command . "cd /Users/me/w/a\n/Users/me/w/b")))))))

(ert-deftest dk-assoc--every-whitespace-character-ends-a-path ()
  (with-syntax-table emacs-lisp-mode-syntax-table
    (should (equal '("/Users/me/w/a" "/Users/me/w/b" "/Users/me/w/c" "/Users/me/w/d")
                   (decknix-session-assoc-input-paths
                    '((command . "ls /Users/me/w/a\t/Users/me/w/b\r\n/Users/me/w/c\v/Users/me/w/d")))))))

(ert-deftest dk-assoc--locations-and-input-are-combined-once ()
  (should (equal '("/Users/me/w/a.kt")
                 (decknix-session-assoc-paths-of
                  '((locations . [((path . "/Users/me/w/a.kt"))])
                    (rawInput . ((file_path . "/Users/me/w/a.kt"))))))))

(ert-deftest dk-assoc--a-root-named-without-a-trailing-slash-resolves ()
  "`cd /w/repo-worktrees/X' names the directory itself."
  (should (equal "/w/repo-worktrees/X"
                 (decknix-session-assoc-resolve
                  "/w/repo-worktrees/X" '("/w/repo" "/w/repo-worktrees/X")))))

(ert-deftest dk-assoc--a-sibling-with-a-shared-prefix-is-not-the-root ()
  "/w/repo-old is not inside /w/repo."
  (should-not (decknix-session-assoc-resolve "/w/repo-old/x" '("/w/repo"))))

;; --- PRs a session created ---------------------------------------------

(defconst dk-assoc-test--create-cmd (concat "cd /w/r && gh pr " "create --draft --title x"))

(defconst dk-assoc-test--bash '(_meta . ((claudeCode . ((toolName . "Bash"))))))

(defun dk-assoc-test--bash (&rest fields)
  "An update of a Bash call carrying FIELDS."
  (cons dk-assoc-test--bash fields))

(ert-deftest dk-assoc--a-creating-call-is-paired-with-its-result ()
  (let ((pending (make-hash-table :test 'equal)) (created nil))
    (setq created (decknix-session-assoc-note-created
                   (dk-assoc-test--bash '(toolCallId . "t1")
                                        `(rawInput . ((command . ,dk-assoc-test--create-cmd))))
                   pending created))
    (should-not created)
    (setq created (decknix-session-assoc-note-created
                   (dk-assoc-test--bash '(toolCallId . "t1")
                                        '(rawOutput . "https://github.com/ExampleOwner/web-integration/pull/89"))
                   pending created))
    (should (equal '("ExampleOwner/web-integration#89") created))))

(ert-deftest dk-assoc--a-pr-url-from-another-command-is-not-a-creation ()
  "gh pr view, a comment, or a body mentioning a PR all print URLs."
  (let ((pending (make-hash-table :test 'equal)))
    (should-not (decknix-session-assoc-note-created
                 (dk-assoc-test--bash '(toolCallId . "t2") '(rawInput . ((command . "gh pr view 89"))))
                 pending nil))
    (should-not (decknix-session-assoc-note-created
                 (dk-assoc-test--bash '(toolCallId . "t2") '(rawOutput . "https://github.com/o/r/pull/89"))
                 pending nil))))

(ert-deftest dk-assoc--a-terminal-call-of-another-agent-counts-by-its-kind ()
  "Agents other than Claude Code name no tool, only the ACP kind."
  (let ((pending (make-hash-table :test 'equal)))
    (decknix-session-assoc-note-created
     `((toolCallId . "k") (kind . "execute") (rawInput . ((command . ,dk-assoc-test--create-cmd))))
     pending nil)
    (should (equal '("o/r#3")
                   (decknix-session-assoc-note-created
                    '((toolCallId . "k") (rawOutput . "https://github.com/o/r/pull/3"))
                    pending nil)))))

(ert-deftest dk-assoc--created-prs-are-read-from-log-lines ()
  (let* ((call (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "a")
                                    `(rawInput . ((command . ,dk-assoc-test--create-cmd)))))
         (result (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "a")
                                      '(rawOutput . "https://github.com/acme-dev/platform-cli/pull/61")))
         (lines (list (json-encode `((params . ((update . ,call)))))
                      (json-encode `((params . ((update . ,result))))))))
    (should (equal '("acme-dev/platform-cli#61")
                   (decknix-session-assoc-created-from-lines lines)))))

(defun dk-assoc-test--log-line (update)
  (json-encode `((jsonrpc . "2.0") (method . "session/update")
                 (params . ((sessionId . "sid") (update . ,update))))))

(defun dk-assoc-test--published (url action)
  (concat "!Unexpected case: "
          (json-encode `((type . "system") (subtype . "code_change_published")
                         (provider . "github") (url . ,url) (action . ,action)
                         (session_id . "sid")))))

(ert-deftest dk-assoc--every-pr-a-creating-call-prints-is-recorded ()
  "A loop raising three PRs in one call printed three URLs, and only the
first was kept."
  (should (equal '("o/a#1" "o/b#2" "o/c#3")
                 (decknix-session-assoc-created-from-lines
                  (list
                   (dk-assoc-test--log-line
                    (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "loop")
                                         `(rawInput . ((command . ,(concat "for r in a b c; do " dk-assoc-test--create-cmd " -R o/$r; done"))))))
                   (dk-assoc-test--log-line
                    (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "loop")
                                         '(status . "completed")
                                         '(rawOutput . "https://github.com/o/a/pull/1\nhttps://github.com/o/b/pull/2\nhttps://github.com/o/c/pull/3\n"))))))))

(ert-deftest dk-assoc--a-sub-agents-creation-is-its-parents ()
  "A sub-agent's Bash call streams through the parent's log."
  (should (equal '("o/r#5")
                 (decknix-session-assoc-created-from-lines
                  (list
                   (dk-assoc-test--log-line
                    `((_meta . ((claudeCode . ((toolName . "Bash") (parentToolUseId . "toolu_agent")))))
                      (sessionUpdate . "tool_call") (toolCallId . "sub")
                      (rawInput . ((command . ,dk-assoc-test--create-cmd)))))
                   (dk-assoc-test--log-line
                    `((_meta . ((claudeCode . ((toolName . "Bash") (parentToolUseId . "toolu_agent")))))
                      (sessionUpdate . "tool_call_update") (toolCallId . "sub") (status . "completed")
                      (rawOutput . "https://github.com/o/r/pull/5"))))))))

(ert-deftest dk-assoc--an-agent-call-mentioning-gh-pr-create-is-not-a-creation ()
  "The parent's Agent call names `gh pr create' in its prompt, and the
sub-agent's summary quotes another PR: that PR is not the session's."
  (should-not (decknix-session-assoc-created-from-lines
               (list
                (dk-assoc-test--log-line
                 `((_meta . ((claudeCode . ((toolName . "Agent")))))
                   (sessionUpdate . "tool_call") (toolCallId . "toolu_agent") (kind . "think")
                   (rawInput . ((prompt . ,(concat "Open the PR with " dk-assoc-test--create-cmd))
                                (command . ,dk-assoc-test--create-cmd)))))
                (dk-assoc-test--log-line
                 '((_meta . ((claudeCode . ((toolName . "Agent")))))
                   (sessionUpdate . "tool_call_update") (toolCallId . "toolu_agent") (status . "completed")
                   (rawOutput . "Done; it builds on https://github.com/o/r/pull/77")))))))

(ert-deftest dk-assoc--a-published-creation-event-is-a-source ()
  (should (equal '("o/r#9")
                 (decknix-session-assoc-created-from-lines
                  (list (dk-assoc-test--published "https://github.com/o/r/pull/8" "commented")
                        (dk-assoc-test--published "https://github.com/o/r/pull/9" "created")
                        (dk-assoc-test--published "https://github.com/o/r/pull/9" "edited"))))))

(ert-deftest dk-assoc--a-pr-seen-by-both-sources-is-recorded-once ()
  (should (equal '("o/r#9")
                 (decknix-session-assoc-created-from-lines
                  (list
                   (dk-assoc-test--log-line
                    (dk-assoc-test--bash '(toolCallId . "m") `(rawInput . ((command . ,dk-assoc-test--create-cmd)))))
                   (dk-assoc-test--published "https://github.com/o/r/pull/9" "created")
                   (dk-assoc-test--log-line
                    (dk-assoc-test--bash '(toolCallId . "m") '(status . "completed")
                                         '(rawOutput . "https://github.com/o/r/pull/9"))))))))

(ert-deftest dk-assoc--a-pr-body-in-the-command-is-not-output ()
  "Earlier updates may echo the command in `content'; its body names PRs."
  (should (equal '("o/r#9")
                 (decknix-session-assoc-created-from-lines
                  (list
                   (dk-assoc-test--log-line
                    (dk-assoc-test--bash '(toolCallId . "m")
                                         `(rawInput . ((command . ,dk-assoc-test--create-cmd)))
                                         '(content . [((type . "content") (content . ((text . "like https://github.com/o/r/pull/4"))))])))
                   (dk-assoc-test--log-line
                    (dk-assoc-test--bash '(toolCallId . "m") '(status . "completed")
                                         '(rawOutput . "https://github.com/o/r/pull/9"))))))))

;; --- stores ------------------------------------------------------------

(ert-deftest dk-assoc--created-prs-persist-and-reload ()
  (let* ((dir (make-temp-file "dk-created-" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
         (decknix--agent-created-store 'unloaded))
    (unwind-protect
        (progn
          (decknix-session-assoc-remember-created "s-1" '("o/r#1"))
          (setq decknix--agent-created-store 'unloaded)
          (should (equal '("o/r#1") (decknix-session-assoc-created "s-1")))
          (should-not (decknix-session-assoc-created "s-2"))
          (should-not (directory-files (expand-file-name "decknix" dir) nil "\\.tmp-")))
      (delete-directory dir t))))

(ert-deftest dk-assoc--stores-ignore-a-bound-print-length ()
  "Some package bound `print-length' to 200 around a save, and both
stores were written as 200 entries and a literal `...'."
  (let* ((dir (make-temp-file "dk-trunc-" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
         (decknix--agent-created-store 'unloaded)
         (decknix--agent-assoc-store nil))
    (unwind-protect
        (let ((print-length 2) (print-level 2))
          (dolist (k '("s-1" "s-2" "s-3"))
            (decknix-session-assoc-remember-created k '("o/r#1"))
            (decknix-session-assoc-remember k 1 '(("/w/a" . 1))))
          (setq decknix--agent-created-store 'unloaded)
          (decknix-session-assoc-load)
          (should (= 3 (length (decknix--session-assoc-created-store))))
          (should (= 3 (length decknix--agent-assoc-store)))
          (should (equal '(1 ("/w/a" . 1)) (decknix-session-assoc-recall "s-1"))))
      (delete-directory dir t))))

(ert-deftest dk-assoc--truncated-stores-keep-their-good-entries ()
  "A store saved truncated reads back without the `...', instead of
failing every later `car' on it."
  (let* ((dir (make-temp-file "dk-trunc-read-" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
         (decknix--agent-created-store 'unloaded)
         (decknix--agent-assoc-store nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "decknix" dir) t)
          (with-temp-file (decknix-session-assoc-created-file)
            (insert "((\"s-1\" \"o/r#1\") ...)"))
          (with-temp-file (decknix-session-assoc-state-file)
            (insert "((\"s-1\" 1 (\"/w/a\" . 1)) ...)"))
          (should (equal '("o/r#1") (decknix-session-assoc-created "s-1")))
          (decknix-session-assoc-remember-created "s-2" '("o/r#2"))
          (should (equal '("o/r#1") (decknix-session-assoc-created "s-1")))
          (decknix-session-assoc-load)
          (should (equal '(1 ("/w/a" . 1)) (decknix-session-assoc-recall "s-1")))
          (decknix-session-assoc-remember "s-2" 2 nil)
          (should (= 2 (length decknix--agent-assoc-store))))
      (delete-directory dir t))))

(defmacro dk-assoc-test--with-state (&rest body)
  "Run BODY with every created-PR store in a fresh state dir."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "dk-created-state-" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (decknix--agent-created-store 'unloaded)
          (decknix--agent-created-offsets 'unloaded)
          (decknix--session-assoc-created-seen (make-hash-table :test 'equal))
          (decknix--session-assoc-created-dirty nil))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(ert-deftest dk-assoc--offsets-persist-and-reload ()
  (dk-assoc-test--with-state
    (decknix-session-assoc-created-set-offset "s-1" 120 '("t1"))
    (decknix-session-assoc-created-set-offset "s-2" 7 nil)
    (setq decknix--agent-created-offsets 'unloaded)
    (should (equal '(120 "t1") (decknix-session-assoc-created-offset "s-1")))
    (should (equal '(7) (decknix-session-assoc-created-offset "s-2")))
    (should-not (decknix-session-assoc-created-offset "s-3"))))

(ert-deftest dk-assoc--a-damaged-offsets-file-is-read-from-zero ()
  (dk-assoc-test--with-state
    (make-directory (expand-file-name "decknix" dir) t)
    (with-temp-file (decknix-session-assoc-created-offsets-file)
      (insert "((\"s-1\" 40 \"t\") (\"s-2\" . junk) (\"s-3\" -1) ...)"))
    (should (equal '(40 "t") (decknix-session-assoc-created-offset "s-1")))
    (should-not (decknix-session-assoc-created-offset "s-2"))
    (should-not (decknix-session-assoc-created-offset "s-3"))))

;; --- incremental scan ---------------------------------------------------

(defun dk-assoc-test--created-log-lines ()
  "A broker log: one creation, PR URLs printed by other calls, a big line."
  (list
   (dk-assoc-test--log-line
    (dk-assoc-test--bash '(sessionUpdate . "tool_call") '(toolCallId . "view")
                         '(rawInput . ((command . "gh pr view 7")))))
   (dk-assoc-test--log-line
    (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "view")
                         '(rawOutput . "https://github.com/o/r/pull/7")))
   (dk-assoc-test--log-line
    (dk-assoc-test--bash '(sessionUpdate . "tool_call") '(toolCallId . "make")
                         `(rawInput . ((command . ,dk-assoc-test--create-cmd)))))
   (dk-assoc-test--log-line
    (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "list")
                         `(rawOutput . ,(concat (make-string 200000 ?x)
                                                " https://github.com/o/r/pull/8"))))
   (dk-assoc-test--log-line
    (dk-assoc-test--bash '(sessionUpdate . "tool_call_update") '(toolCallId . "make")
                         '(status . "completed")
                         '(rawOutput . "https://github.com/o/r/pull/9 ✓")))))

(defmacro dk-assoc-test--with-log (var lines &rest body)
  (declare (indent 2))
  `(let ((,var (make-temp-file "dk-created-log-")))
     (unwind-protect
         (progn
           (with-temp-file ,var
             (dolist (l ,lines) (insert l "\n")))
           ,@body)
       (delete-file ,var))))

(defun dk-assoc-test--append (log text)
  (write-region text nil log t 'silent))

(defun dk-assoc-test--size (log)
  (file-attribute-size (file-attributes log)))

(ert-deftest dk-assoc--a-chunk-scan-agrees-with-reading-every-line ()
  (let ((lines (dk-assoc-test--created-log-lines)))
    (dk-assoc-test--with-log log lines
      (let ((res (decknix-session-assoc-created-scan-chunk log 0 nil)))
        (should (equal (decknix-session-assoc-created-from-lines lines)
                       (plist-get res :prs)))
        (should (equal '("o/r#9") (plist-get res :prs)))
        (should (= (dk-assoc-test--size log) (plist-get res :offset)))
        (should (plist-get res :complete))
        (should-not (plist-get res :pending))))))

(ert-deftest dk-assoc--a-scan-resumes-where-the-last-stopped ()
  "The creating call is read in one scan, its output in the next."
  (dk-assoc-test--with-log log (list (dk-assoc-test--log-line
                                      (dk-assoc-test--bash '(toolCallId . "make")
                                                           `(rawInput . ((command . ,dk-assoc-test--create-cmd))))))
    (let ((first (decknix-session-assoc-created-scan-chunk log 0 nil)))
      (should-not (plist-get first :prs))
      (should (equal '("make") (plist-get first :pending)))
      (dk-assoc-test--append log (concat (dk-assoc-test--log-line
                                          (dk-assoc-test--bash '(toolCallId . "make") '(status . "completed")
                                                               '(rawOutput . "https://github.com/o/r/pull/9")))
                                         "\n"))
      (let ((second (decknix-session-assoc-created-scan-chunk
                     log (plist-get first :offset) (plist-get first :pending))))
        (should (equal '("o/r#9") (plist-get second :prs)))
        (should-not (plist-get second :pending))
        (should (= (dk-assoc-test--size log) (plist-get second :offset)))))))

(ert-deftest dk-assoc--a-line-still-being-written-is-read-whole-later ()
  (dk-assoc-test--with-log log nil
    (let* ((line (dk-assoc-test--published "https://github.com/o/r/pull/9" "created"))
           (half (/ (length line) 2)))
      (dk-assoc-test--append log (substring line 0 half))
      (let ((first (decknix-session-assoc-created-scan-chunk log 0 nil)))
        (should (= 0 (plist-get first :offset)))
        (should-not (plist-get first :prs))
        (dk-assoc-test--append log (concat (substring line half) "\n"))
        (should (equal '("o/r#9")
                       (plist-get (decknix-session-assoc-created-scan-chunk
                                   log (plist-get first :offset) nil)
                                  :prs)))))))

(ert-deftest dk-assoc--a-log-that-shrank-is-read-from-the-start ()
  (dk-assoc-test--with-log log (list (dk-assoc-test--published "https://github.com/o/r/pull/9" "created"))
    (let ((res (decknix-session-assoc-created-scan-chunk log 1000000 nil)))
      (should (plist-get res :reset))
      (should (equal '("o/r#9") (plist-get res :prs)))
      (should (= (dk-assoc-test--size log) (plist-get res :offset))))))

(ert-deftest dk-assoc--a-capped-scan-reads-the-log-in-chunks ()
  "Every chunk ends on a line boundary, and the chunks add up to the whole."
  (let ((lines (dk-assoc-test--created-log-lines)))
    (dk-assoc-test--with-log log lines
      (let ((offset 0) (pending nil) (prs nil) (scans 0) res)
        (while (progn
                 (setq res (decknix-session-assoc-created-scan-chunk log offset pending 300)
                       offset (plist-get res :offset)
                       pending (plist-get res :pending)
                       prs (append prs (plist-get res :prs))
                       scans (1+ scans))
                 (not (plist-get res :complete))))
        (should (> scans 2))
        (should (= (dk-assoc-test--size log) offset))
        (should (equal '("o/r#9") prs))))))

(ert-deftest dk-assoc--a-scan-reads-a-line-longer-than-its-cap ()
  (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
    (let ((res (decknix-session-assoc-created-scan-chunk log 0 nil 10)))
      (should (> (plist-get res :offset) 0)))))

(ert-deftest dk-assoc--an-empty-or-missing-log-is-nothing ()
  (should (equal 0 (plist-get (decknix-session-assoc-created-scan-chunk "/nonexistent/x.log" 0 nil)
                              :offset)))
  (dk-assoc-test--with-log log nil
    (should (plist-get (decknix-session-assoc-created-scan-chunk log 0 nil) :complete))))

;; --- mirroring into the conversation -----------------------------------

(defmacro dk-assoc-test--with-links (links &rest body)
  "Run BODY with conversation \"ck\" holding LINKS (a variable) for broker key s-1."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "dk-agent")))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () (list buf)))
                   ((symbol-function 'decknix--agent-linked-prs) (lambda (_ck) ,links))
                   ((symbol-function 'decknix--agent-pr-url-accessor)
                    (lambda (rec field) (alist-get (intern field) rec)))
                   ((symbol-function 'decknix--agent-link-pr)
                    (lambda (ck url type added)
                      (should (equal "ck" ck))
                      (setq ,links (append ,links (list `((url . ,url) (type . ,type) (added . ,added)))))
                      t)))
           (with-current-buffer buf
             (setq-local decknix--agent-broker-key "s-1")
             (setq-local decknix--agent-conv-key "ck"))
           ,@body)
       (kill-buffer buf))))

(ert-deftest dk-assoc--a-new-created-pr-is-linked-to-the-conversation ()
  (dk-assoc-test--with-state
    (let ((links nil))
      (dk-assoc-test--with-links links
        (should (equal '("o/r#9") (decknix-session-assoc-created-record "s-1" '("o/r#9"))))
        (should (equal '(((url . "https://github.com/o/r/pull/9") (type . "authored") (added . "auto")))
                       links))
        (should (equal '("o/r#9") (decknix-session-assoc-created "s-1")))))))

(ert-deftest dk-assoc--a-pr-recorded-before-is-neither-new-nor-relinked ()
  (dk-assoc-test--with-state
    (let ((links nil))
      (dk-assoc-test--with-links links
        (decknix-session-assoc-remember-created "s-1" '("O/R#9"))
        (should-not (decknix-session-assoc-created-record "s-1" '("o/r#9")))
        (should-not links)))))

(ert-deftest dk-assoc--a-manual-link-is-left-alone ()
  (dk-assoc-test--with-state
    (let ((links (list '((url . "https://github.com/O/R/pull/9/files") (type . "authored") (added . "manual")))))
      (dk-assoc-test--with-links links
        (decknix-session-assoc-created-record "s-1" '("o/r#9"))
        (should (= 1 (length links)))
        (should (equal "manual" (alist-get 'added (car links))))))))

(ert-deftest dk-assoc--a-detached-session-links-through-its-stored-broker-key ()
  (let ((convs (make-hash-table :test 'equal)) (entry (make-hash-table :test 'equal)))
    (puthash "brokerKey" "s-9" entry)
    (puthash "ck9" entry convs)
    (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () nil))
              ((symbol-function 'decknix--agent-tags-read) (lambda () 'store))
              ((symbol-function 'decknix--agent-tags-conversations) (lambda (_s) convs)))
      (should (equal "ck9" (decknix-session-assoc-conv-key-for "s-9")))
      (should-not (decknix-session-assoc-conv-key-for "s-0")))))

;; --- scan out of process, scheduled -------------------------------------

(defun dk-assoc-test--await (pred)
  "Wait up to a minute for PRED: a child Emacs can take seconds to start."
  (let ((deadline (+ (float-time) 60)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(ert-deftest dk-assoc--created-scan-runs-in-a-child-process ()
  "Same answer as the in-process scan, computed by another process."
  (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
    (let* ((got 'none)
           (proc (decknix-session-assoc-created-scan
                  log 0 nil (lambda (res) (setq got res)))))
      (should (processp proc))
      (dk-assoc-test--await (lambda () (not (eq got 'none))))
      (should (equal (decknix-session-assoc-created-scan-chunk log 0 nil) got)))))

(ert-deftest dk-assoc--created-scan-reports-a-failed-scan ()
  (let* ((got 'none)
         (invocation-directory "/usr/bin/")
         (invocation-name "false"))
    (decknix-session-assoc-created-scan "/nonexistent" 0 nil (lambda (res) (setq got res)))
    (dk-assoc-test--await (lambda () (not (eq got 'none))))
    (should (eq 'error got))))

(defmacro dk-assoc-test--with-sessions (spec &rest body)
  "Run BODY with live agent buffers for SPEC, a list of (KEY . LOG)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "dk-created-tick-" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (decknix--agent-created-store 'unloaded)
          (decknix--agent-created-offsets 'unloaded)
          (decknix--session-assoc-created-seen (make-hash-table :test 'equal))
          (decknix--session-assoc-created-dirty nil)
          (decknix--agent-assoc-store nil)
          (decknix--session-assoc-created-scan nil)
          (decknix--session-assoc-backfill-proc nil)
          (spec ,spec)
          (bufs (mapcar (lambda (s)
                          (with-current-buffer (generate-new-buffer "dk-agent")
                            (setq-local decknix--agent-broker-key (car s))
                            (setq-local decknix--agent-assoc-backfilled t)
                            (current-buffer)))
                        spec)))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-shell-buffers) (lambda () bufs))
                   ((symbol-function 'decknix-session-assoc-created-soon) #'ignore)
                   ((symbol-function 'decknix--agent-broker-log-path)
                    (lambda (key) (cdr (assoc key spec)))))
           ,@body)
       (dolist (p (list decknix--session-assoc-created-scan
                        decknix--session-assoc-backfill-proc))
         (when (processp p)
           (set-process-sentinel p #'ignore)
           (delete-process p)))
       (mapc #'kill-buffer bufs)
       (delete-directory dir t))))

(ert-deftest dk-assoc--the-tick-scans-without-blocking-and-records ()
  (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
    (dk-assoc-test--with-sessions (list (cons "s-1" log))
      (decknix-session-assoc-created-tick)
      (should (process-live-p decknix--session-assoc-created-scan))
      (should-not (decknix-session-assoc-created "s-1"))
      (dk-assoc-test--await (lambda () (null decknix--session-assoc-created-scan)))
      (should (equal '("o/r#9") (decknix-session-assoc-created "s-1")))
      (should (equal (list (dk-assoc-test--size log))
                     (decknix-session-assoc-created-offset "s-1")))
      (should-not (decknix-session-assoc-created-due-p "s-1" log)))))

(ert-deftest dk-assoc--a-pr-raised-after-the-first-scan-is-recovered ()
  "The scan used to run once per session ever; anything later was lost."
  (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
    (dk-assoc-test--with-sessions (list (cons "s-1" log))
      (decknix-session-assoc-created-tick)
      (dk-assoc-test--await (lambda () (null decknix--session-assoc-created-scan)))
      (dk-assoc-test--append log (concat (dk-assoc-test--published "https://github.com/o/r/pull/10" "created") "\n"))
      (should (decknix-session-assoc-created-due-p "s-1" log))
      (decknix-session-assoc-created-tick)
      (dk-assoc-test--await (lambda () (null decknix--session-assoc-created-scan)))
      (should (equal '("o/r#9" "o/r#10") (decknix-session-assoc-created "s-1"))))))

(ert-deftest dk-assoc--the-tick-runs-one-scan-at-a-time ()
  (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
    (dk-assoc-test--with-sessions (list (cons "s-1" log) (cons "s-2" log))
      (let ((first (decknix-session-assoc-created-tick)))
        (should (processp first))
        (should-not (decknix-session-assoc-created-tick))
        (should (eq first decknix--session-assoc-created-scan))))))

(ert-deftest dk-assoc--a-session-whose-turn-ended-is-scanned-first ()
  (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
    (dk-assoc-test--with-sessions (list (cons "s-1" log) (cons "s-2" log))
      (decknix-session-assoc-created-turn-ended "s-2")
      (decknix-session-assoc-created-turn-ended "s-2")
      (should (equal '("s-2") decknix--session-assoc-created-dirty))
      (should (equal "s-2" (car (decknix-session-assoc-created-next))))
      (should-not decknix--session-assoc-created-dirty))))

(ert-deftest dk-assoc--a-failed-scan-is-not-retried-until-the-log-grows ()
  (let ((invocation-directory "/usr/bin/")
        (invocation-name "false"))
    (dk-assoc-test--with-log log (dk-assoc-test--created-log-lines)
      (dk-assoc-test--with-sessions (list (cons "s-1" log))
        (decknix-session-assoc-created-tick)
        (dk-assoc-test--await (lambda () (null decknix--session-assoc-created-scan)))
        (should-not (decknix-session-assoc-created "s-1"))
        (should-not (decknix-session-assoc-created-due-p "s-1" log))
        (dk-assoc-test--append log "{}\n")
        (should (decknix-session-assoc-created-due-p "s-1" log))))))

(ert-deftest dk-assoc--a-pr-captured-live-is-kept-by-a-later-scan ()
  (dk-assoc-test--with-sessions (list (cons "s-1" "/dev/null"))
    (decknix-session-assoc-created-record "s-1" '("o/r#1"))
    (decknix-session-assoc-created-record "s-1" '("o/r#9" "o/r#1"))
    (should (equal '("o/r#1" "o/r#9") (decknix-session-assoc-created "s-1")))))

(ert-deftest dk-assoc--live-capture-records-every-pr-of-a-call ()
  (dk-assoc-test--with-sessions (list (cons "s-1" "/dev/null"))
    (with-current-buffer (car (agent-shell-buffers))
      (should-not (decknix-session-assoc-observe-created
                   (dk-assoc-test--bash '(toolCallId . "c")
                                        `(rawInput . ((command . ,dk-assoc-test--create-cmd))))))
      (should (equal "o/r#2"
                     (decknix-session-assoc-observe-created
                      (dk-assoc-test--bash '(toolCallId . "c") '(status . "completed")
                                           '(rawOutput . "https://github.com/o/r/pull/1 https://github.com/o/r/pull/2")))))
      (should (equal '("o/r#1" "o/r#2") (decknix-session-assoc-created "s-1"))))))

(ert-deftest dk-assoc--a-turn-end-asks-for-a-scan ()
  (dk-assoc-test--with-sessions (list (cons "s-1" "/dev/null"))
    (with-current-buffer (car (agent-shell-buffers))
      (cl-letf (((symbol-function 'decknix-session-assoc-save) #'ignore))
        (decknix-session-assoc-end-turn))
      (should (equal '("s-1") decknix--session-assoc-created-dirty)))))

(defconst dk-assoc-test--assoc-log-lines
  (list
   "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"locations\":[{\"path\":\"/w/a/x.go\"}]}}}"
   "{\"id\":1,\"result\":{\"stopReason\":\"end_turn\"}}"
   "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"locations\":[{\"path\":\"/w/b/y.go\"}]}}}"))

(ert-deftest dk-assoc--the-association-backfill-runs-in-a-child-emacs ()
  "Same answer as the in-process backfill, computed by another process."
  (dk-assoc-test--with-log log dk-assoc-test--assoc-log-lines
    (let ((got 'none))
      (should (processp (decknix-session-assoc-backfill-async
                         log '("/w/a" "/w/b") (lambda (res) (setq got res)))))
      (dk-assoc-test--await (lambda () (not (eq got 'none))))
      (should (equal (decknix-session-assoc-backfill log '("/w/a" "/w/b")) got))
      (should (cdr got)))))

(ert-deftest dk-assoc--the-idle-tick-backfills-the-association-in-a-child ()
  (dk-assoc-test--with-log log dk-assoc-test--assoc-log-lines
    (dk-assoc-test--with-sessions (list (cons "s-1" log))
      (let ((buf (car (agent-shell-buffers))))
        (with-current-buffer buf (setq-local decknix--agent-assoc-backfilled nil))
        (cl-letf (((symbol-function 'decknix-session-assoc-roots)
                   (lambda () '("/w/a" "/w/b")))
                  ((symbol-function 'decknix-session-assoc-save) #'ignore))
          (decknix-session-assoc-backfill-tick)
          (should (process-live-p decknix--session-assoc-backfill-proc))
          (decknix-session-assoc-backfill-tick)
          (should-not decknix--session-assoc-created-scan)
          (dk-assoc-test--await (lambda () (null decknix--session-assoc-backfill-proc)))
          (should (equal '("/w/b" "/w/a")
                         (with-current-buffer buf
                           (decknix-session-assoc-active
                            decknix--agent-assoc decknix--agent-assoc-turn 20)))))))))

(provide 'decknix-session-assoc-test)
;;; decknix-session-assoc-test.el ends here
