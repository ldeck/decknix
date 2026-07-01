;;; decknix-agent-post-create-test.el --- Tests for post-create policy -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Characterisation tests for `decknix-agent-post-create' (PR B.83).

;;; Code:

(require 'ert)
(require 'decknix-agent-post-create)

;; --- flush-mode ---

(ert-deftest decknix-post-create--immediate-when-conv-key-and-metadata ()
  "conv-key + tags -> immediate."
  (should (eq 'immediate
              (decknix--post-create-flush-mode
               "abc123" '("review") nil)))
  (should (eq 'immediate
              (decknix--post-create-flush-mode
               "abc123" nil "/tmp/proj")))
  (should (eq 'immediate
              (decknix--post-create-flush-mode
               "abc123" '("a") "/tmp/proj"))))

(ert-deftest decknix-post-create--immediate-even-without-metadata ()
  "conv-key alone is enough for immediate (the conv-key handoff still happens)."
  (should (eq 'immediate
              (decknix--post-create-flush-mode "abc123" nil nil))))

(ert-deftest decknix-post-create--deferred-with-metadata ()
  "Nil conv-key + tags -> deferred-with-metadata."
  (should (eq 'deferred-with-metadata
              (decknix--post-create-flush-mode nil '("review") nil)))
  (should (eq 'deferred-with-metadata
              (decknix--post-create-flush-mode nil nil "/tmp/proj")))
  (should (eq 'deferred-with-metadata
              (decknix--post-create-flush-mode
               nil '("review") "/tmp/proj"))))

(ert-deftest decknix-post-create--deferred-no-metadata ()
  "Nil conv-key + nil tags + nil ws -> deferred-no-metadata."
  (should (eq 'deferred-no-metadata
              (decknix--post-create-flush-mode nil nil nil))))

;; --- buffer-name ---

(ert-deftest decknix-post-create--buffer-name-format ()
  "Standard name produces *Auggie: NAME* format."
  (should (equal "*Auggie: my-session*"
                 (decknix--post-create-buffer-name "my-session"))))

(ert-deftest decknix-post-create--buffer-name-empty ()
  "Empty name still wrapped (caller's responsibility to validate)."
  (should (equal "*Auggie: *"
                 (decknix--post-create-buffer-name ""))))

(ert-deftest decknix-post-create--buffer-name-with-spaces ()
  "Names containing spaces preserved verbatim (Emacs allows them)."
  (should (equal "*Auggie: PR Review #42*"
                 (decknix--post-create-buffer-name "PR Review #42"))))

(ert-deftest decknix-post-create--buffer-name-provider-label ()
  "An explicit LABEL drives the *LABEL: NAME* prefix (provider-aware)."
  (should (equal "*Claude: my-session*"
                 (decknix--post-create-buffer-name "my-session" "Claude")))
  (should (equal "*Pi: task*"
                 (decknix--post-create-buffer-name "task" "Pi"))))

(ert-deftest decknix-post-create--buffer-name-label-defaults-to-auggie ()
  "Omitting LABEL falls back to the Auggie default (back-compat)."
  (should (equal "*Auggie: s*"
                 (decknix--post-create-buffer-name "s")))
  (should (equal "*Auggie: s*"
                 (decknix--post-create-buffer-name "s" nil))))

(provide 'decknix-agent-post-create-test)
;;; decknix-agent-post-create-test.el ends here
