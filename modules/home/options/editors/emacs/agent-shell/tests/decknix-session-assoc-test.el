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
(require 'decknix-session-assoc)

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

(ert-deftest dk-assoc--a-sibling-with-a-shared-prefix-does-not-match ()
  "`/w/platform-cli' must not claim `/w/platform-cli-worktrees/...' by
string prefix alone -- that is why resolution compares directories."
  (should-not (equal "/w/platform-cli"
                     (decknix-session-assoc-resolve
                      "/w/platform-cli-worktrees/CONN-1040/x.go"
                      '("/w/platform-cli")))))

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

(provide 'decknix-session-assoc-test)
;;; decknix-session-assoc-test.el ends here
