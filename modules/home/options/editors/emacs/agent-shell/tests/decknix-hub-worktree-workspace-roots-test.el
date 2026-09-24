;;; decknix-hub-worktree-workspace-roots-test.el --- Workspace-root clone discovery -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-hub "0.1"))

;;; Commentary:
;;
;; Pins the workspace-root discovery source for
;; `decknix--hub-worktree-discover-clones'.  A repo cloned under a
;; workspace root (`[repos].workspaces', read by `decknix repos list')
;; must reach the hub even when no agent session was ever anchored in
;; it; its `<repo>-worktrees' then follow from the primary's
;; `git worktree list'.  Discovery must never block a sidebar render:
;; the list is refreshed by an async process and each path is
;; classified through the non-blocking clone map.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-shell-hub)

(defvar decknix--hub-workspace-root-clones nil)
(defvar decknix--hub-workspace-root-clones-time 0.0)
(defvar decknix--hub-worktree-clones-cache nil)

(defmacro decknix-hub-roots-test--with (paths classified &rest body)
  "Run BODY with PATHS as the cached root clones, CLASSIFIED as the clone map.
CLASSIFIED is an alist (PATH . REPO-OR-:unknown).  The async refresh is
stubbed to count calls in `refreshes'."
  (declare (indent 2))
  `(let ((decknix--hub-workspace-root-clones ,paths)
         (decknix--hub-workspace-root-clones-time (float-time))
         (refreshes 0))
     (cl-letf (((symbol-function 'decknix--hub-workspace-root-clones-refresh-async)
                (lambda () (cl-incf refreshes)))
               ((symbol-function 'decknix--hub-worktree-classify-dir)
                (lambda (dir)
                  (or (cdr (assoc (file-name-as-directory dir) ,classified))
                      :unknown))))
       ,@body)))

(ert-deftest decknix-hub-workspace-roots--parse-reads-repo-paths ()
  "The `decknix repos list --json' shape yields each clone's path."
  (should (equal '("/w/a" "/w/b")
                 (decknix--hub-workspace-root-clones-parse
                  "{\"repos\":[{\"org\":\"o\",\"path\":\"/w/a\"},{\"org\":\"o\",\"path\":\"/w/b\"}]}"))))

(ert-deftest decknix-hub-workspace-roots--parse-tolerates-bad-output ()
  "Malformed or unexpected output yields no paths rather than an error."
  (should (null (decknix--hub-workspace-root-clones-parse "not json")))
  (should (null (decknix--hub-workspace-root-clones-parse "{\"other\":1}")))
  (should (equal '("/w/a")
                 (decknix--hub-workspace-root-clones-parse
                  "{\"repos\":[{\"org\":\"o\"},{\"path\":\"/w/a\"}]}"))))

(ert-deftest decknix-hub-workspace-roots--maps-classified-clones ()
  "Classified clones map to (REPO . PATH); unclassified ones wait."
  (decknix-hub-roots-test--with '("/w/a" "/w/b")
      '(("/w/a/" . "o/a"))
    (should (equal '(("o/a" . "/w/a"))
                   (decknix--hub-worktree-discover-from-workspace-roots)))
    (should (= 0 refreshes))))

(ert-deftest decknix-hub-workspace-roots--stale-list-refreshes-without-blocking ()
  "A list older than the TTL starts an async refresh and still answers."
  (decknix-hub-roots-test--with '("/w/a") '(("/w/a/" . "o/a"))
    (let ((decknix-hub-workspace-roots-ttl 300)
          (decknix--hub-workspace-root-clones-time (- (float-time) 301)))
      (should (equal '(("o/a" . "/w/a"))
                     (decknix--hub-worktree-discover-from-workspace-roots)))
      (should (= 1 refreshes)))))

(ert-deftest decknix-hub-workspace-roots--primary-beats-session-worktree ()
  "A workspace-root primary wins over a session anchored in a worktree."
  (let ((decknix-hub-clones nil)
        (decknix--hub-worktree-cache (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'decknix--hub-worktree-discover-from-workspace-roots)
               (lambda () '(("o/a" . "/w/a"))))
              ((symbol-function 'decknix--hub-worktree-discover-from-sessions)
               (lambda () '(("o/a" . "/w/a-worktrees/T-1-x") ("o/b" . "/w/b"))))
              ((symbol-function 'project-known-project-roots) (lambda () nil))
              ((symbol-function 'decknix--hub-worktree-normalize-path)
               (lambda (path) (and path (expand-file-name path)))))
      (let ((clones (decknix--hub-worktree-discover-clones--compute)))
        (should (equal "/w/a" (directory-file-name (cdr (assoc "o/a" clones)))))
        (should (assoc "o/b" clones))))))

(provide 'decknix-hub-worktree-workspace-roots-test)
;;; decknix-hub-worktree-workspace-roots-test.el ends here
