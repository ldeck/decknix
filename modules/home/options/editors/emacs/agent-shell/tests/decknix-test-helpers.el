;;; decknix-test-helpers.el --- Shared helpers for decknix ERT suites -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Test helpers shared across the decknix ERT characterisation suites.
;; Provides macros for binding hub state, isolating the progress
;; persistence directory to a tmp path, and building fixture data.
;;
;; Loaded at the top of every `decknix-*-test.el' file.

;;; Code:

(require 'cl-lib)
(require 'json)

;; Test-side declarations for the hub data layer's free variables.
;; In `decknix-progress.el' these appear as `(defvar X)' without an
;; initializer — that is purely a byte-compiler hint and does NOT
;; mark the symbol globally special, so a plain `let' over the same
;; name in a `lexical-binding: t' test file would bind lexically and
;; the byte-compiled `varref' inside the function under test would
;; raise `void-variable'.  Giving the helpers' defvar a nil initializer
;; sets `declared-special = t' globally, so test-side `let' bindings
;; reach the function dynamically the way they would in a running
;; daemon.  The progress dir / cache vars are always set inside the
;; tmp-dir macro, so a no-init declaration is sufficient there.
(defvar decknix--hub-wip nil)
(defvar decknix--hub-reviews nil)
(defvar decknix--hub-pr-cache nil)
(defvar decknix--hub-pr-cache-ttl nil)
(defvar decknix--sidebar-sessions-age-filter nil)
(defvar decknix--hub-jira-tasks nil)
(defvar decknix--hub-teamcity-builds nil)
(defvar decknix--hub-deploys nil)
(defvar decknix--hub-show-deploys t)
(defvar decknix--hub-org-visibility nil)
(defvar decknix--hub-mention-filter nil)
;; Upstream `agent-shell-workspace' defines this with value "*Agent
;; Sidebar*"; carved hub modules now consult the variable (not a
;; literal) when deciding whether to refresh the sidebar, so the
;; helper provides the same default so toggle tests see a bound
;; symbol without loading the whole workspace package.
(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")
(defvar decknix-progress--dir)
(defvar decknix-progress--index-cache)
(defvar decknix-progress--todo-cache)

(defmacro decknix-test-with-tmp-progress-dir (&rest body)
  "Run BODY with `decknix-progress--dir' bound to a fresh tmp directory.
The tmp directory is created before BODY runs and removed afterwards.
Also clears any cached index parse so each test starts cold."
  (declare (indent 0))
  `(let* ((tmp (make-temp-file "decknix-progress-" t))
          (decknix-progress--dir (file-name-as-directory tmp))
          (decknix-progress--index-cache nil))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p tmp)
         (delete-directory tmp t)))))

(defmacro decknix-test-with-hub-data (wip jira &rest body)
  "Bind `decknix--hub-wip' to WIP and `decknix--hub-jira-tasks' to JIRA in BODY."
  (declare (indent 2))
  `(let ((decknix--hub-wip ,wip)
         (decknix--hub-jira-tasks ,jira))
     ,@body))

(defun decknix-test-make-pr (&rest props)
  "Build a hub WipPr-shaped alist from PROPS (a plist).
Defaults: state=open, draft=nil, ci=pass, mergeable=mergeable.
Pass :ci-status to override the inner ci alist."
  (let* ((number (or (plist-get props :number) 1))
         (title (or (plist-get props :title) "Example PR"))
         (state (or (plist-get props :state) "open"))
         (draft (plist-get props :draft))
         (merged-at (plist-get props :merged-at))
         (mergeable (or (plist-get props :mergeable) "mergeable"))
         (review-decision (plist-get props :review-decision))
         (needs-reply (plist-get props :needs-reply))
         (bot-pending (plist-get props :bot-pending))
         (replies-to-me (plist-get props :replies-to-me))
         (total-threads (plist-get props :total-threads))
         (unresolved-threads (plist-get props :unresolved-threads))
         (ci-status (or (plist-get props :ci-status) "pass"))
         (url (or (plist-get props :url)
                  (format "https://github.com/o/r/pull/%s" number))))
    `((number . ,number)
      (title . ,title)
      (url . ,url)
      (state . ,state)
      (draft . ,draft)
      (merged_at . ,merged-at)
      (mergeable . ,mergeable)
      (review_decision . ,review-decision)
      (needs_reply . ,needs-reply)
      (bot_pending . ,bot-pending)
      (replies_to_me . ,replies-to-me)
      (total_threads . ,total-threads)
      (unresolved_threads . ,unresolved-threads)
      (ci . ((status . ,ci-status))))))

(defun decknix-test-make-hub-wip (repo-prs)
  "Build a `decknix--hub-wip'-shaped alist from REPO-PRS.
REPO-PRS is a list of (REPO . PR-LIST) cons cells."
  `((repos . ,(mapcar (lambda (rp)
                        `((repo . ,(car rp))
                          (prs . ,(cdr rp))))
                      repo-prs))))

(defun decknix-test-make-jira-task (&rest props)
  "Build a hub JiraTask-shaped alist from PROPS (plist)."
  (let ((status (or (plist-get props :status) "To Do"))
        (cat (or (plist-get props :status-category) "new"))
        (links (plist-get props :links))
        (key (or (plist-get props :key) "TEST-1"))
        (summary (or (plist-get props :summary) "Example task")))
    `((key . ,key)
      (summary . ,summary)
      (status . ,status)
      (status_category . ,cat)
      (links . ,links))))

(defun decknix-test-make-teamcity-build (&rest props)
  "Build a hub TeamCity build alist from PROPS (plist).
Mirrors the shape `decknix--hub-tc-build-for-branch' consumes:
keys are `branch', `state' (running/queued/finished), `status'
\(SUCCESS/FAILURE/ERROR), and optional `progress_pct'."
  (let ((branch  (or (plist-get props :branch) "main"))
        (state   (or (plist-get props :state) "finished"))
        (status  (or (plist-get props :status) "SUCCESS"))
        (pct     (plist-get props :progress-pct)))
    `((branch . ,branch)
      (state . ,state)
      (status . ,status)
      (progress_pct . ,pct))))

(defun decknix-test-make-teamcity-env (&rest props)
  "Build one `environments' alist entry from PROPS (plist).
Mirrors the shape `decknix--hub-deploy-indicator' iterates over:
keys are `env' (development/testing/stable/production/uk_production),
`status' (SUCCESS/FAILURE/ERROR), `state' (finished/running/queued),
and `finished' (ISO-8601 UTC timestamp string, optional)."
  (let ((env      (or (plist-get props :env) "stable"))
        (status   (or (plist-get props :status) "SUCCESS"))
        (state    (or (plist-get props :state) "finished"))
        (finished (plist-get props :finished)))
    `((env . ,env)
      (status . ,status)
      (state . ,state)
      (finished . ,finished))))

(defun decknix-test-make-teamcity-deploys (repo-branches)
  "Build a `decknix--hub-deploys'-shaped alist from REPO-BRANCHES.
REPO-BRANCHES is a list of (REPO BRANCH ENV-ENTRIES...) where each
ENV-ENTRY is itself an alist as produced by
`decknix-test-make-teamcity-env'.  Matches the shape consumed by
`decknix--hub-deploy-indicator'."
  `((repos . ,(mapcar
               (lambda (rb)
                 (let ((repo (nth 0 rb))
                       (branch (nth 1 rb))
                       (envs (nthcdr 2 rb)))
                   `((repo . ,repo)
                     (branches . (((branch . ,branch)
                                   (environments . ,envs)))))))
               repo-branches))))

;; -- Stubbing for not-yet-extracted dependencies ------------------
;;
;; Modules extracted from the heredoc reference symbols defined
;; elsewhere in `default.el' (e.g. `agent-shell-workspace-sidebar-refresh',
;; `decknix-agent-prefix-map') that aren't loaded in the test
;; environment.  At runtime the modules guard those calls with
;; `(when (fboundp ...))', so this macro feeds a `cl-letf' rebinding
;; that records each call into a counter so tests can assert "refresh
;; was triggered" without dragging in agent-shell-workspace.

(defvar decknix-test--stub-calls nil
  "Alist of (SYMBOL . LIST-OF-ARGLISTS) recording stubbed-function invocations.
The list is in reverse-call-order (most recent first), so
`(car (alist-get sym decknix-test--stub-calls))' is the most
recent call's arglist.  Bound by `decknix-test-with-stubbed-deps'.")

(defun decknix-test-stub-call-count (symbol)
  "Return the number of times stubbed SYMBOL was called inside the macro."
  (length (alist-get symbol decknix-test--stub-calls)))

(defun decknix-test-stub-call-args (symbol &optional n)
  "Return the arglist of the Nth-from-most-recent call to stubbed SYMBOL.
N defaults to 0 (most recent call).  Returns nil if SYMBOL was
never called or N is out of range."
  (nth (or n 0) (alist-get symbol decknix-test--stub-calls)))

(defmacro decknix-test-with-stubbed-deps (stubs &rest body)
  "Run BODY with STUBS bound as no-op functions that record calls.
STUBS is a list of symbols; each is rebound via `cl-letf' to a
function that pushes its arglist onto `decknix-test--stub-calls'
under that key and returns nil.  Use `decknix-test-stub-call-count'
to assert the function was triggered, and `decknix-test-stub-call-args'
to inspect the values it was called with.

Stubs only intercept calls that go through the symbol's function
cell, so tests targeting code that uses `(when (fboundp 'foo) (foo))'
work without modification."
  (declare (indent 1))
  `(let ((decknix-test--stub-calls nil))
     (cl-letf (,@(mapcar
                  (lambda (sym)
                    `((symbol-function ',sym)
                      (lambda (&rest args)
                        (setf (alist-get ',sym decknix-test--stub-calls)
                              (cons args (alist-get ',sym decknix-test--stub-calls)))
                        nil)))
                  stubs))
       ,@body)))

;; -- Snapshot helper ------------------------------------------------
;;
;; Compares a rendered substring against an expected one, returning
;; nil on match and a multi-line diff-shaped string on mismatch so
;; ERT's `should' surfaces both versions in the failure message.

(defun decknix-test-render-snapshot (actual expected)
  "Return nil when ACTUAL equals EXPECTED, else a diff-shaped message.
Both arguments are strings.  Use inside ERT with
  (should (null (decknix-test-render-snapshot actual expected)))
so a regression prints both the rendered and expected forms."
  (if (string= actual expected)
      nil
    (format "snapshot mismatch:\n--- expected ---\n%s\n--- actual ---\n%s\n--- end ---"
            expected actual)))

(defun decknix-test-read-json-file (path)
  "Read PATH as JSON and return the parsed hash table."
  (with-temp-buffer
    (insert-file-contents path)
    (json-parse-buffer
     :object-type 'hash-table
     :array-type 'list
     :null-object nil
     :false-object nil)))

(provide 'decknix-test-helpers)
;;; decknix-test-helpers.el ends here
