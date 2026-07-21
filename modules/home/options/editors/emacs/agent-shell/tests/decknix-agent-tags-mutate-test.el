;;; decknix-agent-tags-mutate-test.el --- Tests for tags-mutate -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-tags-mutate' (PR B.70).
;; Stubs the tag-store read/write/conversations + conversation-key
;; functions via `cl-letf' so the tests never touch
;; `~/.config/decknix/agent-sessions.json'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-tags-mutate)

;; Buffer-locals owned by main-bulk; declared dynamic so `let' binds
;; specially during tests.
(defvar decknix--agent-conv-key nil)
(defvar decknix--agent-auggie-session-id nil)
(defvar decknix--agent-pending-tags nil)
(defvar decknix--agent-pending-workspace nil)
(defvar decknix--agent-workspace-persisted nil)

(defun decknix-test--make-store (convs)
  "Return a fake store hash whose CONVS slot is preseeded with CONVS."
  (let ((store (make-hash-table :test 'equal)))
    (puthash "conversations" convs store)
    store))

(defmacro decknix-test--with-store (initial &rest body)
  "Run BODY with a tag-store stubbed to start as INITIAL.
Captures the most recent write into `last-store'."
  (declare (indent 1))
  `(let* ((convs (or ,initial (make-hash-table :test 'equal)))
          (store (decknix-test--make-store convs))
          (last-store nil))
     (cl-letf (((symbol-function 'decknix--agent-tags-read)
                (lambda () store))
               ((symbol-function 'decknix--agent-tags-write)
                (lambda (s) (setq last-store s)))
               ((symbol-function 'decknix--agent-tags-conversations)
                (lambda (s) (gethash "conversations" s))))
       ,@body)))

(ert-deftest decknix-store-metadata-by-conv-key--nil-conv-key-noop ()
  "No-op when CONV-KEY is nil; never writes."
  (decknix-test--with-store nil
    (decknix--agent-store-metadata-by-conv-key nil '("review") "/ws")
    (should-not last-store)))

(ert-deftest decknix-store-metadata-by-conv-key--creates-fresh-entry ()
  "Creates a new entry with tags, workspace, and lastAccessed."
  (decknix-test--with-store nil
    (decknix--agent-store-metadata-by-conv-key "key1" '("review") "/ws")
    (should last-store)
    (let* ((entry (gethash "key1" convs)))
      (should entry)
      (should (equal (gethash "tags" entry) '("review")))
      (should (string= (gethash "workspace" entry) "/ws"))
      (should (stringp (gethash "lastAccessed" entry))))))

(ert-deftest decknix-store-metadata-by-conv-key--merges-tags ()
  "Merges new tags into existing without duplicates."
  (let* ((existing-entry (make-hash-table :test 'equal)))
    (puthash "tags" '("foo") existing-entry)
    (puthash "sessions" nil existing-entry)
    (let ((convs (make-hash-table :test 'equal)))
      (puthash "key1" existing-entry convs)
      (decknix-test--with-store convs
        (decknix--agent-store-metadata-by-conv-key "key1" '("foo" "bar") nil)
        (let ((entry (gethash "key1" convs)))
          (should (= (length (gethash "tags" entry)) 2))
          (should (member "foo" (gethash "tags" entry)))
          (should (member "bar" (gethash "tags" entry))))))))

(ert-deftest decknix-register-session-id--nil-args-noop ()
  "No-op when CONV-KEY or SESSION-ID is nil."
  (decknix-test--with-store nil
    (decknix--agent-register-session-id nil "sid")
    (decknix--agent-register-session-id "key" nil)
    (should-not last-store)))

(ert-deftest decknix-register-session-id--creates-entry-when-missing ()
  "Creates a fresh conversation entry when the conv-key has none yet.
A brand-new (untagged) session must be linked so it is recoverable at
restore time -- previously this no-opped and the session was orphaned."
  (decknix-test--with-store nil
    (decknix--agent-register-session-id "missing" "sid")
    (should last-store)
    (let ((entry (gethash "missing" convs)))
      (should entry)
      (should (equal (gethash "sessions" entry) '("sid"))))))

(ert-deftest decknix-register-session-id--prepends-new-session ()
  "Prepends a new session id to the existing list."
  (let* ((entry (make-hash-table :test 'equal)))
    (puthash "sessions" '("old-sid") entry)
    (let ((convs (make-hash-table :test 'equal)))
      (puthash "k" entry convs)
      (decknix-test--with-store convs
        (decknix--agent-register-session-id "k" "new-sid")
        (should last-store)
        (should (equal (gethash "sessions" (gethash "k" convs))
                       '("new-sid" "old-sid")))))))

(ert-deftest decknix-register-session-id--idempotent-on-duplicate ()
  "No-op when the session id is already present."
  (let* ((entry (make-hash-table :test 'equal)))
    (puthash "sessions" '("sid-a" "sid-b") entry)
    (let ((convs (make-hash-table :test 'equal)))
      (puthash "k" entry convs)
      (decknix-test--with-store convs
        (decknix--agent-register-session-id "k" "sid-a")
        (should-not last-store)))))

(ert-deftest decknix-flush-pending-metadata--empty-input-noop ()
  "Whitespace-only input is ignored."
  (decknix-test--with-store nil
    (cl-letf (((symbol-function 'decknix--agent-conversation-key)
               (lambda (_) "should-not-be-called")))
      (decknix--agent-flush-pending-metadata "  \t\n")
      (should-not last-store))))

(ert-deftest decknix-flush-pending-metadata--persists-tags-and-ws ()
  "Persists pending tags + workspace and clears the buffer-locals."
  (decknix-test--with-store nil
    (cl-letf (((symbol-function 'decknix--agent-conversation-key)
               (lambda (_) "ck"))
              ((symbol-function 'remove-hook) (lambda (&rest _) nil))
              ((symbol-function 'message) (lambda (&rest _) nil)))
      (let ((decknix--agent-conv-key nil)
            (decknix--agent-auggie-session-id nil)
            (decknix--agent-pending-tags '("rev"))
            (decknix--agent-pending-workspace "/ws")
            (decknix--agent-workspace-persisted nil))
        (decknix--agent-flush-pending-metadata "hello world")
        (should last-store)
        (let ((entry (gethash "ck" convs)))
          (should (equal (gethash "tags" entry) '("rev")))
          (should (string= (gethash "workspace" entry) "/ws")))))))

;; -- backfill pure helpers -----------------------------------------

;; Prefer the real deps when on the load path; fall back to faithful
;; stubs so the suite is self-contained in the package test harness.
(require 'decknix-agent-parse nil t)
(require 'decknix-agent-url-parse nil t)
(unless (fboundp 'decknix--agent-canonicalize-command-message)
  (defun decknix--agent-canonicalize-command-message (m) m))
(unless (fboundp 'decknix--agent-parse-pr-url)
  (defun decknix--agent-parse-pr-url (url)
    (when (string-match "github\\.com/[^/]+/\\([^/]+\\)/pull/\\([0-9]+\\)" url)
      (list (cons 'repo (match-string 1 url))
            (cons 'number (match-string 2 url))))))

(ert-deftest decknix-agent-tags-backfill-review-tags--literal ()
  "A literal review command yields (review REPO #<n>)."
  (should (equal (decknix--agent-tags-backfill-review-tags
                  "/review-service-pr https://github.com/o/svc/pull/1311")
                 '("review" "svc" "#1311"))))

(ert-deftest decknix-agent-tags-backfill-review-tags--bot-variant ()
  "The bot-review command is also recognised."
  (should (equal (decknix--agent-tags-backfill-review-tags
                  "/review-bot-pr https://github.com/o/beholder/pull/9")
                 '("review" "beholder" "#9"))))

(ert-deftest decknix-agent-tags-backfill-review-tags--non-review-nil ()
  "Non-review messages return nil."
  (should-not (decknix--agent-tags-backfill-review-tags "/ship 42"))
  (should-not (decknix--agent-tags-backfill-review-tags "just a chat message"))
  (should-not (decknix--agent-tags-backfill-review-tags nil)))

(provide 'decknix-agent-tags-mutate-test)

;;; decknix-agent-tags-mutate-test.el ends here
