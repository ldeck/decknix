;;; decknix-review-clone-test.el --- Tests for the org->workspace map and on-demand clone -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-review-clone "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; Specification for `decknix-workspace-orgs' (which workspace a GitHub
;; org's repositories belong in, and where a review runs) and
;; `decknix-review-clone' (the asynchronous clone, its per-repository
;; state and the board's row text).  The clone child process is stubbed
;; through `decknix-review-clone-start-function'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-workspace-orgs)
(require 'decknix-review-clone)

(defconst decknix-review-clone-test--workspaces
  '(("acme" :path "/ws/acme" :orgs ("Acme" "acme-infra"))
    ("me" :path "/ws/me" :orgs ("my-user") :clone-args ("--depth=1"))))

(defmacro decknix-review-clone-test--with-fresh-state (&rest body)
  "Run BODY with empty clone state, the fixture map and no hooks."
  (declare (indent 0))
  `(let ((decknix-workspaces decknix-review-clone-test--workspaces)
         (decknix-review-clone--states (make-hash-table :test 'equal))
         (decknix-review-clone--waiters (make-hash-table :test 'equal))
         (decknix-review-clone--primaries (make-hash-table :test 'equal))
         (decknix-review-clone--resolve-memo (make-hash-table :test 'equal))
         (decknix-review-clone--queue nil)
         (decknix-review-clone--running 0)
         (decknix-review-clone-state-change-hook nil))
     ,@body))

;; -- org -> workspace ----------------------------------------------

(ert-deftest decknix-workspace/org-match-is-case-insensitive ()
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal "/ws/acme/" (decknix-workspace-for-org "acme")))
    (should (equal "/ws/acme/" (decknix-workspace-for-org "ACME")))
    (should (equal "/ws/acme/" (decknix-workspace-for-org "Acme-Infra")))))

(ert-deftest decknix-workspace/several-workspaces-each-own-their-orgs ()
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal "/ws/me/" (decknix-workspace-for-org "my-user")))
    (should-not (decknix-workspace-for-org "stranger"))
    (should-not (decknix-workspace-for-org nil))
    (should-not (decknix-workspace-for-org ""))))

(ert-deftest decknix-workspace/clone-args-per-workspace-then-default ()
  (let ((decknix-workspaces decknix-review-clone-test--workspaces)
        (decknix-workspace-default-clone-args '("--filter=blob:none")))
    (should (equal '("--depth=1") (decknix-workspace-clone-args "my-user")))
    (should (equal '("--filter=blob:none") (decknix-workspace-clone-args "acme")))
    (should (equal '("--filter=blob:none") (decknix-workspace-clone-args "stranger")))))

;; -- resolution ----------------------------------------------------

(ert-deftest decknix-workspace/resolve-detected-checkout-wins ()
  "The established detection wins even when the org maps elsewhere."
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal '(:kind checkout :workspace "/elsewhere/" :primary nil)
                   (decknix-workspace-resolve
                    "acme" "widget"
                    (lambda (_o _r) "/elsewhere/")
                    (lambda (_o _r) (error "Primary must not be consulted"))
                    (lambda (_p) nil))))))

(ert-deftest decknix-workspace/resolve-known-primary-runs-from-org-workspace ()
  "A checkout outside the org's workspace is used, from the org's workspace."
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal '(:kind checkout :workspace "/ws/me/" :primary "/tools/fw")
                   (decknix-workspace-resolve
                    "my-user" "fw" (lambda (_o _r) nil)
                    (lambda (_o _r) "/tools/fw") (lambda (_p) nil))))))

(ert-deftest decknix-workspace/resolve-known-primary-without-mapping ()
  (let ((decknix-workspaces nil))
    (should (equal '(:kind checkout :workspace "/tools/" :primary "/tools/fw")
                   (decknix-workspace-resolve
                    "stranger" "fw" nil (lambda (_o _r) "/tools/fw")
                    (lambda (_p) nil))))))

(ert-deftest decknix-workspace/resolve-reuses-clone-already-in-workspace ()
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal '(:kind checkout :workspace "/ws/acme/" :primary "/ws/acme/widget")
                   (decknix-workspace-resolve
                    "ACME" "widget" (lambda (_o _r) nil) (lambda (_o _r) nil)
                    (lambda (p) (equal p "/ws/acme/widget")))))))

(ert-deftest decknix-workspace/resolve-mapped-without-checkout-clones ()
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal '(:kind clone :workspace "/ws/acme/" :target "/ws/acme/widget")
                   (decknix-workspace-resolve
                    "acme-infra" "widget" (lambda (_o _r) nil) (lambda (_o _r) nil)
                    (lambda (_p) nil))))))

(ert-deftest decknix-workspace/resolve-neither-is-unmapped ()
  (let ((decknix-workspaces decknix-review-clone-test--workspaces))
    (should (equal '(:kind unmapped :org "stranger")
                   (decknix-workspace-resolve
                    "stranger" "widget" (lambda (_o _r) nil) (lambda (_o _r) nil)
                    (lambda (_p) nil))))))

;; -- clone command -------------------------------------------------

(ert-deftest decknix-review-clone/command-gh-passes-git-args-after-dashes ()
  (let ((decknix-review-clone-program "gh"))
    (should (equal '("gh" "repo" "clone" "acme/widget" "/ws/acme/widget"
                     "--" "--filter=blob:none")
                   (decknix-review-clone-command
                    "acme" "widget" "/ws/acme/widget" '("--filter=blob:none"))))
    (should (equal '("gh" "repo" "clone" "acme/widget" "/ws/acme/widget")
                   (decknix-review-clone-command "acme" "widget" "/ws/acme/widget")))))

(ert-deftest decknix-review-clone/command-git ()
  (let ((decknix-review-clone-program "git"))
    (should (equal '("git" "clone" "--depth=1"
                     "https://github.com/acme/widget.git" "/ws/acme/widget")
                   (decknix-review-clone-command
                    "acme" "widget" "/ws/acme/widget" '("--depth=1"))))))

;; -- async clone ---------------------------------------------------

(defun decknix-review-clone-test--tmp-target (repo)
  "Return a not-yet-existing target path for REPO under a temp dir."
  (expand-file-name repo (make-temp-file "review-clone-" t)))

(ert-deftest decknix-review-clone/success-calls-back-with-the-checkout ()
  (decknix-review-clone-test--with-fresh-state
    (let* ((target (decknix-review-clone-test--tmp-target "widget"))
           (started nil) (result nil)
           (decknix-review-clone-start-function
            (lambda (key command) (push (cons key command) started))))
      (decknix-review-clone-ensure "Acme" "widget" target
                                   (lambda (ok v) (setq result (list ok v))))
      (should (= 1 (length started)))
      (should (eq 'cloning (plist-get (decknix-review-clone-state "acme" "widget") :state)))
      (should-not result)
      (decknix-review-clone--finish "acme/widget" t "")
      (should (equal (list t target) result))
      (should-not (decknix-review-clone-state "acme" "widget"))
      (should (equal target (decknix-review-clone-known-primary "ACME" "widget")))
      (should (= 0 decknix-review-clone--running)))))

(ert-deftest decknix-review-clone/failure-records-the-error-for-the-row ()
  (decknix-review-clone-test--with-fresh-state
    (let* ((target (decknix-review-clone-test--tmp-target "widget"))
           (result nil)
           (decknix-review-clone-start-function #'ignore))
      (decknix-review-clone-ensure "acme" "widget" target
                                   (lambda (ok v) (setq result (list ok v))))
      (decknix-review-clone--finish
       "acme/widget" nil "Cloning into...\nGraphQL: Could not resolve to a Repository\n")
      (should (equal '(nil "GraphQL: Could not resolve to a Repository") result))
      (let ((state (decknix-review-clone-state "acme" "widget")))
        (should (eq 'failed (plist-get state :state)))
        (should (equal "clone failed: GraphQL: Could not resolve to a Repository"
                       (decknix-review-clone-row-note state)))))))

(ert-deftest decknix-review-clone/one-clone-per-repository ()
  "Two dispatches for one repository share one clone."
  (decknix-review-clone-test--with-fresh-state
    (let* ((target (decknix-review-clone-test--tmp-target "widget"))
           (starts 0) (calls 0)
           (decknix-review-clone-start-function (lambda (&rest _) (cl-incf starts))))
      (decknix-review-clone-ensure "acme" "widget" target (lambda (&rest _) (cl-incf calls)))
      (decknix-review-clone-ensure "acme" "widget" target (lambda (&rest _) (cl-incf calls)))
      (should (= 1 starts))
      (decknix-review-clone--finish "acme/widget" t "")
      (should (= 2 calls)))))

(ert-deftest decknix-review-clone/concurrency-is-capped ()
  (decknix-review-clone-test--with-fresh-state
    (let* ((decknix-review-clone-max-concurrent 1)
           (started nil)
           (decknix-review-clone-start-function
            (lambda (key _cmd) (push key started))))
      (decknix-review-clone-ensure "acme" "a" (decknix-review-clone-test--tmp-target "a") #'ignore)
      (decknix-review-clone-ensure "acme" "b" (decknix-review-clone-test--tmp-target "b") #'ignore)
      (should (equal '("acme/a") started))
      (should (eq 'queued (plist-get (decknix-review-clone-state "acme" "b") :state)))
      (decknix-review-clone--finish "acme/a" t "")
      (should (equal '("acme/b" "acme/a") started)))))

(ert-deftest decknix-review-clone/existing-checkout-is-reused-without-cloning ()
  (decknix-review-clone-test--with-fresh-state
    (let* ((target (make-temp-file "review-clone-existing-" t))
           (result nil)
           (decknix-review-clone-start-function
            (lambda (&rest _) (error "Must not clone over a checkout"))))
      (decknix-review-clone-ensure "acme" "widget" target
                                   (lambda (ok v) (setq result (list ok v))))
      (should (equal (list t (directory-file-name target)) result)))))

(ert-deftest decknix-review-clone/clone-appearing-while-queued-is-reused ()
  (decknix-review-clone-test--with-fresh-state
    (let* ((decknix-review-clone-max-concurrent 1)
           (late (decknix-review-clone-test--tmp-target "late"))
           (started nil) (result nil)
           (decknix-review-clone-start-function
            (lambda (key _cmd) (push key started))))
      (decknix-review-clone-ensure "acme" "first" (decknix-review-clone-test--tmp-target "first") #'ignore)
      (decknix-review-clone-ensure "acme" "late" late (lambda (ok v) (setq result (list ok v))))
      (make-directory late t)
      (decknix-review-clone--finish "acme/first" t "")
      (should (equal '("acme/first") started))
      (should (equal (list t late) result)))))

(ert-deftest decknix-review-clone/unmapped-is-announced-once-and-clearable ()
  (decknix-review-clone-test--with-fresh-state
    (should (decknix-review-clone-mark-unmapped "stranger" "widget"))
    (should-not (decknix-review-clone-mark-unmapped "stranger" "widget"))
    (should (equal "no workspace for stranger: add it to decknix.workspaces (C clones elsewhere)"
                   (decknix-review-clone-row-note
                    (decknix-review-clone-state "stranger" "widget"))))
    (decknix-review-clone-clear "stranger" "widget")
    (should-not (decknix-review-clone-state "stranger" "widget"))))

(ert-deftest decknix-review-clone/state-changes-run-the-hook ()
  (decknix-review-clone-test--with-fresh-state
    (let* ((runs 0)
           (decknix-review-clone-state-change-hook (list (lambda () (cl-incf runs))))
           (decknix-review-clone-start-function #'ignore))
      (decknix-review-clone-ensure "acme" "widget"
                                   (decknix-review-clone-test--tmp-target "widget") #'ignore)
      (decknix-review-clone--finish "acme/widget" nil "boom")
      ;; queued, cloning, failed
      (should (= 3 runs)))))

;; -- row text ------------------------------------------------------

(ert-deftest decknix-review-clone/row-note-per-state ()
  (should (equal "clone queued..." (decknix-review-clone-row-note '(:state queued))))
  (should (equal "cloning..." (decknix-review-clone-row-note '(:state cloning))))
  (should (equal "not cloned: d clones into /ws/acme"
                 (decknix-review-clone-row-note
                  nil '(:kind clone :workspace "/ws/acme/" :target "/ws/acme/w"))))
  (should (string-prefix-p "no workspace for stranger"
                           (decknix-review-clone-row-note
                            nil '(:kind unmapped :org "stranger"))))
  (should-not (decknix-review-clone-row-note
               nil '(:kind checkout :workspace "/ws/acme/"))))

(ert-deftest decknix-review-clone/row-resolution-starts-no-process ()
  "The board's per-row note must not run a process on the render path."
  (decknix-review-clone-test--with-fresh-state
    (cl-letf (((symbol-function 'decknix--agent-pr-detect-workspace)
               (lambda (&rest _) nil))
              ((symbol-function 'call-process)
               (lambda (&rest _) (error "Synchronous process on render path")))
              ((symbol-function 'process-file)
               (lambda (&rest _) (error "Synchronous process on render path")))
              ((symbol-function 'make-process)
               (lambda (&rest _) (error "Process started on render path"))))
      (should (equal "not cloned: d clones into /ws/acme"
                     (decknix-review-clone-row-note
                      (decknix-review-clone-state "acme" "nowhere-xyz")
                      (decknix-review-clone-resolve-cached "acme" "nowhere-xyz")))))))

(ert-deftest decknix-review-clone/row-resolution-is-memoised ()
  (decknix-review-clone-test--with-fresh-state
    (let ((calls 0))
      (cl-letf (((symbol-function 'decknix--agent-pr-detect-workspace)
                 (lambda (&rest _) (cl-incf calls) "/ws/acme/")))
        (decknix-review-clone-resolve-cached "acme" "w")
        (decknix-review-clone-resolve-cached "acme" "w")
        (should (= 1 calls))))))

(provide 'decknix-review-clone-test)
;;; decknix-review-clone-test.el ends here
