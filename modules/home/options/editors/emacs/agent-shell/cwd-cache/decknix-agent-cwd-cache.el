;;; decknix-agent-cwd-cache.el --- Cached CWD resolution for agent shells -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, performance, decknix

;;; Commentary:
;;
;; `agent-shell-cwd' resolves a shell's working directory by asking
;; `project-current' for a VC root, and agent-shell calls it once per
;; tool-call label while a response streams.  That is fine inside a
;; repository -- `locate-dominating-file' finds `.git' in the first
;; directory it looks at -- but it is expensive precisely where we spend
;; most of our time.
;;
;; Our agents are usually launched at the WORKSPACE ROOT
;; (`~/Code/nurturecloud/'), which contains the repositories and
;; worktrees but is not itself a repository.  Neither is `~/Code', nor
;; `~'.  So `project-current' walks the whole way to `/', finds nothing,
;; and returns nil -- and project.el does not cache a negative result,
;; so the identical failing walk is repeated on the next label.
;;
;; Measured on this machine:
;;
;;   ~/Code/nurturecloud/   2.61 ms/call   (project-current -> nil)
;;   ~/tools/decknix/       0.02 ms/call   (finds .git immediately)
;;
;; A 130x gap, and the slow side is the common one.  In a 5s profile of
;; a wedged daemon this path held 57 of 468 main-thread samples (12%).
;;
;; The fix is a cache keyed by DIRECTORY rather than by shell: several
;; agents share one workspace root, so they share one entry, and the
;; miss cost is paid once per directory for the daemon's lifetime.
;; Caching the NEGATIVE answer is the whole point -- "there is no
;; project here" is the expensive answer to compute.
;;
;; Wired in via `agent-shell-cwd-function', an upstream defcustom that
;; short-circuits `agent-shell-cwd' before it consults projectile or
;; project.el, so this needs no advice.
;;
;; Public surface:
;;
;;   `decknix-agent-cwd-cached'      -- dir, resolver -> cached result
;;   `decknix-agent-cwd-resolve'     -- the `agent-shell-cwd-function'
;;   `decknix-agent-cwd-cache-clear' -- drop the cache (new worktree/repo)
;;   `decknix-agent-cwd-cache-size'  -- entry count, for tests + diagnosis

;;; Code:

(require 'subr-x)

(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function projectile-project-root "ext:projectile" (&optional dir))

(defcustom decknix-agent-cwd-cache-limit 512
  "Maximum number of directories held in the CWD cache.

A guard against unbounded growth in a long-lived daemon that visits
many directories.  On overflow the cache is cleared wholesale rather
than evicted entry-by-entry: entries are cheap to recompute, the limit
is far above the handful of workspace roots in real use, and an LRU
would cost more bookkeeping than the lookups it protects."
  :type 'integer
  :group 'decknix)

(defvar decknix-agent-cwd--cache (make-hash-table :test 'equal)
  "Directory -> resolved CWD.  Populated by `decknix-agent-cwd-cached'.")

(defun decknix-agent-cwd-cache-size ()
  "Return the number of directories currently cached."
  (hash-table-count decknix-agent-cwd--cache))

(defun decknix-agent-cwd-cache-clear ()
  "Drop every cached CWD resolution.

Worth calling after creating a worktree or `git init'-ing a directory
that agents already resolved: a path that had no project root a moment
ago may have one now, and the cache would otherwise keep answering
with the stale walk-to-root result."
  (interactive)
  (clrhash decknix-agent-cwd--cache)
  (when (called-interactively-p 'interactive)
    (message "decknix: CWD cache cleared")))

(defun decknix-agent-cwd-cached (dir resolver)
  "Return the resolved CWD for DIR, calling RESOLVER only on a miss.

RESOLVER is a function of one argument (DIR) returning a directory
string.  A nil DIR is not cacheable and is passed straight through.

A resolver returning nil IS cached: nil is the expensive answer here
\(no project root anywhere above DIR), so declining to cache it would
defeat the purpose.  `gethash' with a distinct default sentinel is
what lets a cached nil be told apart from an absent key."
  (if (null dir)
      (funcall resolver dir)
    (let ((hit (gethash dir decknix-agent-cwd--cache 'decknix-agent-cwd--miss)))
      (if (not (eq hit 'decknix-agent-cwd--miss))
          hit
        (when (>= (hash-table-count decknix-agent-cwd--cache)
                  decknix-agent-cwd-cache-limit)
          (clrhash decknix-agent-cwd--cache))
        (let ((val (funcall resolver dir)))
          (puthash dir val decknix-agent-cwd--cache)
          val)))))

(defun decknix-agent-cwd--resolve-uncached (dir)
  "Resolve DIR to a project root, or DIR itself when there is none.

Mirrors upstream `agent-shell-cwd''s precedence (projectile, then
project.el, then the directory as-is) so installing this as
`agent-shell-cwd-function' changes only WHEN the work happens, never
WHAT it answers."
  (let ((default-directory dir))
    (or (when (and (boundp 'projectile-mode)
                   (symbol-value 'projectile-mode)
                   (fboundp 'projectile-project-root))
          (projectile-project-root))
        (when (fboundp 'project-root)
          (when-let* ((proj (project-current)))
            (project-root proj)))
        dir)))

(defun decknix-agent-cwd-resolve ()
  "Return this shell's CWD, resolving project roots at most once per directory.

Installed as `agent-shell-cwd-function'.  Upstream calls that hook
before its own projectile / project.el probes, so this fully replaces
the per-tool-call `project-current' walk."
  (decknix-agent-cwd-cached default-directory
                            #'decknix-agent-cwd--resolve-uncached))

(provide 'decknix-agent-cwd-cache)
;;; decknix-agent-cwd-cache.el ends here
