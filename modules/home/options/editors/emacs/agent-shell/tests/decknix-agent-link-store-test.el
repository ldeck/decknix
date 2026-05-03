;;; decknix-agent-link-store-test.el --- Tests for per-conv link store -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-link-store "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for the per-conversation link store
;; extracted from the main heredoc.  Covers all seven entry points:
;; the three accessors (linked-items / linked-prs / linked-repos),
;; the two PR mutators (link-pr / unlink-pr), and the two repo
;; mutators (link-repo / unlink-repo).
;;
;; Tests run against an isolated tags-store on a per-test mktemp
;; dir so the user's `~/.config/decknix/agent-sessions.json' is
;; never touched.  Hub-side post-mutation callbacks
;; (`decknix--hub-write-linked-prs', `decknix--hub-pr-fetch-async',
;; `decknix--hub-repo-fetch-async') are stubbed via `cl-letf' so we
;; can both assert they fired and prevent any real I/O.

;;; Code:

(require 'ert)
(require 'cl-lib)

(unless (fboundp 'decknix--agent-session-list)
  (defun decknix--agent-session-list () nil))
(unless (fboundp 'decknix--agent-conversation-key)
  (defun decknix--agent-conversation-key (_first-message) nil))

(require 'decknix-agent-tags-store)
(require 'decknix-agent-link-store)

(defmacro decknix-agent-link-store-test--with-isolated-store (&rest body)
  "Evaluate BODY against a fresh tags-store on a per-test mktemp dir.
All hub-side callbacks are no-op'd so the test never reaches the
hub daemon or the on-disk linked-prs.json."
  (declare (indent 0))
  `(let* ((tmp-dir (file-name-as-directory
                    (make-temp-file "agent-link-store-" t)))
          (decknix--agent-tags-file
           (expand-file-name "agent-sessions.json" tmp-dir))
          (decknix--agent-tags-cache nil)
          (decknix--agent-tags-cache-mtime nil)
          (decknix--agent-tags-cache-checked-at 0.0))
     (cl-letf (((symbol-function 'decknix--hub-write-linked-prs)
                (lambda () nil))
               ((symbol-function 'decknix--hub-pr-fetch-async)
                (lambda (_url) nil))
               ((symbol-function 'decknix--hub-repo-fetch-async)
                (lambda (_url _branch) nil)))
       (unwind-protect
           (progn ,@body)
         (when (file-directory-p tmp-dir)
           (delete-directory tmp-dir t))))))

;; -- accessors -----------------------------------------------------

(ert-deftest decknix-agent-link-store--linked-items-empty ()
  "Accessors return nil for unknown conv-keys + nil conv-key."
  (decknix-agent-link-store-test--with-isolated-store
    (should-not (decknix--agent-linked-items nil))
    (should-not (decknix--agent-linked-items "nope"))
    (should-not (decknix--agent-linked-prs   "nope"))
    (should-not (decknix--agent-linked-repos "nope"))))

;; -- link-pr -------------------------------------------------------

(ert-deftest decknix-agent-link-store--link-pr-roundtrips ()
  "`link-pr' adds a PR record visible via linked-items + linked-prs."
  (decknix-agent-link-store-test--with-isolated-store
    (should (decknix--agent-link-pr
             "conv1" "https://github.com/o/r/pull/1"))
    (let ((items (decknix--agent-linked-items "conv1"))
          (prs   (decknix--agent-linked-prs   "conv1"))
          (repos (decknix--agent-linked-repos "conv1")))
      (should (= 1 (length items)))
      (should (= 1 (length prs)))
      (should (null repos))
      (let ((rec (car prs)))
        (should (equal "https://github.com/o/r/pull/1"
                       (gethash "url" rec)))
        (should (equal "authored" (gethash "type"  rec)))
        (should (equal "manual"   (gethash "added" rec)))
        (should (stringp (gethash "linked_at" rec)))))))

(ert-deftest decknix-agent-link-store--link-pr-rejects-non-pr-url ()
  "`link-pr' is a no-op when URL fails `pr-parse-url'."
  (decknix-agent-link-store-test--with-isolated-store
    (should-not (decknix--agent-link-pr
                 "conv1" "https://example.com/not-a-pr"))
    (should-not (decknix--agent-linked-items "conv1"))))

(ert-deftest decknix-agent-link-store--link-pr-dedupes ()
  "Linking the same URL twice leaves a single record."
  (decknix-agent-link-store-test--with-isolated-store
    (decknix--agent-link-pr "c" "https://github.com/o/r/pull/2")
    (decknix--agent-link-pr "c" "https://github.com/o/r/pull/2")
    (should (= 1 (length (decknix--agent-linked-prs "c"))))))

(ert-deftest decknix-agent-link-store--link-pr-fires-hub-callbacks ()
  "`link-pr' invokes hub write + fetch on a successful link."
  (decknix-agent-link-store-test--with-isolated-store
    (let ((wrote nil) (fetched nil))
      (cl-letf (((symbol-function 'decknix--hub-write-linked-prs)
                 (lambda () (setq wrote t)))
                ((symbol-function 'decknix--hub-pr-fetch-async)
                 (lambda (url) (setq fetched url))))
        (decknix--agent-link-pr "c" "https://github.com/o/r/pull/3"))
      (should wrote)
      (should (equal "https://github.com/o/r/pull/3" fetched)))))

;; -- unlink-pr -----------------------------------------------------

(ert-deftest decknix-agent-link-store--unlink-pr-removes-record ()
  "`unlink-pr' drops the PR record but leaves repo records alone."
  (decknix-agent-link-store-test--with-isolated-store
    (decknix--agent-link-pr   "c" "https://github.com/o/r/pull/4")
    (decknix--agent-link-repo "c" "https://github.com/o/r" "main")
    (decknix--agent-unlink-pr "c" "https://github.com/o/r/pull/4")
    (should (null (decknix--agent-linked-prs "c")))
    (should (= 1 (length (decknix--agent-linked-repos "c"))))))

;; -- link-repo / unlink-repo --------------------------------------

(ert-deftest decknix-agent-link-store--link-repo-roundtrips ()
  "`link-repo' adds a repo record with branch + type \"repo\"."
  (decknix-agent-link-store-test--with-isolated-store
    (should (decknix--agent-link-repo "c" "https://github.com/o/r" "dev"))
    (let ((repos (decknix--agent-linked-repos "c")))
      (should (= 1 (length repos)))
      (should (equal "repo" (gethash "type"   (car repos))))
      (should (equal "dev"  (gethash "branch" (car repos)))))))

(ert-deftest decknix-agent-link-store--link-repo-dedupes-on-branch ()
  "Same URL + different branch is a separate record; same+same dedupes."
  (decknix-agent-link-store-test--with-isolated-store
    (decknix--agent-link-repo "c" "https://github.com/o/r" "main")
    (decknix--agent-link-repo "c" "https://github.com/o/r" "dev")
    (decknix--agent-link-repo "c" "https://github.com/o/r" "main")
    (should (= 2 (length (decknix--agent-linked-repos "c"))))))

(ert-deftest decknix-agent-link-store--unlink-repo-targets-branch ()
  "`unlink-repo' removes only the matching URL+branch record."
  (decknix-agent-link-store-test--with-isolated-store
    (decknix--agent-link-repo "c" "https://github.com/o/r" "main")
    (decknix--agent-link-repo "c" "https://github.com/o/r" "dev")
    (decknix--agent-unlink-repo "c" "https://github.com/o/r" "main")
    (let ((remaining (decknix--agent-linked-repos "c")))
      (should (= 1 (length remaining)))
      (should (equal "dev" (gethash "branch" (car remaining)))))))

(provide 'decknix-agent-link-store-test)
;;; decknix-agent-link-store-test.el ends here
