;;; decknix-agent-re-review-test.el --- Tests for re-review routing -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-re-review "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests pinning the re-review routing contract:
;; which hub items count as a re-review, how a PR maps to its session
;; needle, and the live > saved > fresh preference that decides where an
;; open-review action lands.  All pure -- live-buffer lookup is exercised
;; against real temp buffers (created and killed here) rather than a
;; running agent.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-re-review)

;; -- item-p ---------------------------------------------------------

(ert-deftest decknix-agent-re-review-item-p-true-test ()
  "An item the hub flagged `re_requested' is a re-review."
  (should (decknix-agent-re-review-item-p '((re_requested . t)))))

(ert-deftest decknix-agent-re-review-item-p-false-test ()
  "An explicit false is not a re-review."
  (should-not (decknix-agent-re-review-item-p '((re_requested . :json-false))))
  (should-not (decknix-agent-re-review-item-p '((re_requested . nil)))))

(ert-deftest decknix-agent-re-review-item-p-absent-test ()
  "Older hub data lacking the field reads as not-a-re-review."
  (should-not (decknix-agent-re-review-item-p '((number . 12)))))

;; -- needle ---------------------------------------------------------

(ert-deftest decknix-agent-re-review-needle-strips-owner-test ()
  "Only the repo segment is used, matching the minted session name."
  (should (equal (decknix-agent-re-review-needle "UpsideRealty/upside" 20228)
                 "pr-upside-20228")))

(ert-deftest decknix-agent-re-review-needle-bare-repo-test ()
  "A bare repo name works without an owner prefix."
  (should (equal (decknix-agent-re-review-needle "upside" 7) "pr-upside-7")))

(ert-deftest decknix-agent-re-review-needle-string-number-test ()
  "NUMBER may arrive as a string."
  (should (equal (decknix-agent-re-review-needle "o/r" "42") "pr-r-42")))

(ert-deftest decknix-agent-re-review-needle-unresolvable-test ()
  "Missing repo or number yields nil rather than a malformed needle."
  (should-not (decknix-agent-re-review-needle "" 12))
  (should-not (decknix-agent-re-review-needle nil 12))
  (should-not (decknix-agent-re-review-needle "o/r" nil))
  (should-not (decknix-agent-re-review-needle "o/r" "")))

;; -- find-live ------------------------------------------------------

(ert-deftest decknix-agent-re-review-find-live-substring-test ()
  "The needle is matched as a substring of the decorated buffer name."
  (let ((buf (generate-new-buffer "*agent-shell claude pr-upside-20228 ●*")))
    (unwind-protect
        (should (eq (decknix-agent-re-review-find-live "pr-upside-20228" (list buf))
                    buf))
      (kill-buffer buf))))

(ert-deftest decknix-agent-re-review-find-live-no-match-test ()
  "A different PR's buffer is not reused."
  (let ((buf (generate-new-buffer "*agent-shell pr-upside-999*")))
    (unwind-protect
        (should-not (decknix-agent-re-review-find-live "pr-upside-20228" (list buf)))
      (kill-buffer buf))))

(ert-deftest decknix-agent-re-review-find-live-skips-dead-test ()
  "A killed buffer never wins the lookup."
  (let ((dead (generate-new-buffer "*agent-shell pr-upside-20228*")))
    (kill-buffer dead)
    (should-not (decknix-agent-re-review-find-live "pr-upside-20228" (list dead)))))

(ert-deftest decknix-agent-re-review-find-live-nil-needle-test ()
  "A nil needle matches nothing (rather than the first buffer)."
  (let ((buf (generate-new-buffer "*agent-shell pr-upside-20228*")))
    (unwind-protect
        (should-not (decknix-agent-re-review-find-live nil (list buf)))
      (kill-buffer buf))))

;; -- find-saved -----------------------------------------------------

(defconst decknix-agent-re-review-test--entries
  '(((session-id . "s1") (name . "other-work") (tags . ("wip")))
    ((session-id . "s2") (name . "pr-upside-20228") (tags . ("review" "upside" "#20228")))
    ((session-id . "s3") (name . "renamed by hand") (tags . ("review" "upside" "#777"))))
  "Saved-session entries in the sidebar's newest-first shape.")

(ert-deftest decknix-agent-re-review-find-saved-by-name-test ()
  "A saved entry whose derived name embeds the needle matches."
  (should (equal (alist-get 'session-id
                            (decknix-agent-re-review-find-saved
                             "pr-upside-20228" 20228
                             decknix-agent-re-review-test--entries))
                 "s2")))

(ert-deftest decknix-agent-re-review-find-saved-by-tags-test ()
  "A renamed session still matches on its review + #number tags."
  (should (equal (alist-get 'session-id
                            (decknix-agent-re-review-find-saved
                             "pr-upside-777" 777
                             decknix-agent-re-review-test--entries))
                 "s3")))

(ert-deftest decknix-agent-re-review-find-saved-requires-review-tag-test ()
  "A #number tag alone, without `review', is not a review session."
  (should-not (decknix-agent-re-review-find-saved
               "pr-x-1" 1
               '(((session-id . "s") (name . "n") (tags . ("#1")))))))

(ert-deftest decknix-agent-re-review-find-saved-none-test ()
  "An unknown PR yields nil."
  (should-not (decknix-agent-re-review-find-saved
               "pr-upside-1" 1 decknix-agent-re-review-test--entries)))

;; -- target ---------------------------------------------------------

(ert-deftest decknix-agent-re-review-target-prefers-live-test ()
  "A live buffer wins even when a saved entry also matches."
  (let ((buf (generate-new-buffer "*agent-shell pr-upside-20228*")))
    (unwind-protect
        (let ((r (decknix-agent-re-review-target
                  "pr-upside-20228" 20228 (list buf)
                  decknix-agent-re-review-test--entries)))
          (should (eq (car r) 'live))
          (should (eq (cdr r) buf)))
      (kill-buffer buf))))

(ert-deftest decknix-agent-re-review-target-falls-back-to-saved-test ()
  "With no live buffer, the snapshotted session is resumed."
  (let ((r (decknix-agent-re-review-target
            "pr-upside-20228" 20228 nil
            decknix-agent-re-review-test--entries)))
    (should (eq (car r) 'saved))
    (should (equal (alist-get 'session-id (cdr r)) "s2"))))

(ert-deftest decknix-agent-re-review-target-fresh-test ()
  "With nothing to reuse, a fresh review is started."
  (should (equal (decknix-agent-re-review-target "pr-new-1" 1 nil nil)
                 '(fresh))))

(ert-deftest decknix-agent-re-review-prompt-default-test ()
  "The prompt is the user's follow-up wording, not a slash command."
  (should (equal decknix-agent-re-review-prompt
                 "The pr has been updated; please re-review"))
  (should-not (string-prefix-p "/" decknix-agent-re-review-prompt)))

(provide 'decknix-agent-re-review-test)
;;; decknix-agent-re-review-test.el ends here
