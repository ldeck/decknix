;;; decknix-agent-review-followup-io-test.el --- Tests for follow-up I/O quartet -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-review-followup-io "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests pinning the read/write/set-status/
;; delete contract of the carved follow-up stash.  All persistence
;; is redirected to a per-test mktemp file so the user's real
;; `~/.config/decknix/review-followups.json' is never touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-review-followup-io)

(defmacro decknix-test-with-tmp-followups-file (&rest body)
  "Run BODY with `decknix-agent-review-followups-file' shadowed.
The shadowed path lives under a per-test mktemp directory that is
cleaned up on exit, so persistence tests cannot escape into the
user's real config dir."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "decknix-followup-io-" t))
          (decknix-agent-review-followups-file
           (expand-file-name "review-followups.json" dir)))
     (unwind-protect
         (progn ,@body)
       (delete-directory dir t))))

;; -- read ----------------------------------------------------------

(ert-deftest decknix-followup-io-read--missing-file-returns-nil ()
  "Reading from a non-existent stash returns nil."
  (decknix-test-with-tmp-followups-file
    (should-not (file-exists-p decknix-agent-review-followups-file))
    (should (null (decknix--agent-review-followups-read)))))

(ert-deftest decknix-followup-io-read--empty-list-roundtrip ()
  "An empty JSON list parses back as nil (json-array-type=list)."
  (decknix-test-with-tmp-followups-file
    (with-temp-file decknix-agent-review-followups-file
      (insert "[]\n"))
    (should (null (decknix--agent-review-followups-read)))))

(ert-deftest decknix-followup-io-read--corrupt-file-returns-nil ()
  "A corrupt JSON file is reported via `message' and read returns nil."
  (decknix-test-with-tmp-followups-file
    (with-temp-file decknix-agent-review-followups-file
      (insert "{not json"))
    (should (null (decknix--agent-review-followups-read)))))

(ert-deftest decknix-followup-io-read--alist-shape ()
  "Items parse as alists keyed by symbol (not hash-tables / strings)."
  (decknix-test-with-tmp-followups-file
    (with-temp-file decknix-agent-review-followups-file
      (insert "[{\"id\":\"fu-1\",\"status\":\"open\",\"title\":\"x\"}]\n"))
    (let ((items (decknix--agent-review-followups-read)))
      (should (consp items))
      (should (= 1 (length items)))
      (let ((entry (car items)))
        (should (consp entry))
        (should (string= "fu-1" (alist-get 'id entry)))
        (should (string= "open" (alist-get 'status entry)))
        (should (string= "x" (alist-get 'title entry)))))))

;; -- write ---------------------------------------------------------

(ert-deftest decknix-followup-io-write--creates-parent-directory ()
  "Writing to a stash under a missing parent dir creates the dir."
  (let* ((dir (make-temp-file "decknix-followup-io-mkdir-" t))
         (nested (expand-file-name "deep/nest/review-followups.json" dir))
         (decknix-agent-review-followups-file nested))
    (unwind-protect
        (progn
          (decknix--agent-review-followups-write
           '(((id . "fu-1") (status . "open"))))
          (should (file-exists-p nested))
          (should (file-directory-p
                   (file-name-directory nested))))
      (delete-directory dir t))))

(ert-deftest decknix-followup-io-write--trailing-newline ()
  "Written file ends with a newline (diff-friendly)."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open"))))
    (with-temp-buffer
      (insert-file-contents decknix-agent-review-followups-file)
      (goto-char (point-max))
      (should (eq (char-before) ?\n)))))

(ert-deftest decknix-followup-io-write--roundtrip ()
  "Writing then reading recovers the same item set."
  (decknix-test-with-tmp-followups-file
    (let ((items '(((id . "fu-1") (status . "open") (title . "a"))
                   ((id . "fu-2") (status . "done") (title . "b")))))
      (decknix--agent-review-followups-write items)
      (let ((roundtripped (decknix--agent-review-followups-read)))
        (should (= 2 (length roundtripped)))
        (should (string= "fu-1" (alist-get 'id (nth 0 roundtripped))))
        (should (string= "fu-2" (alist-get 'id (nth 1 roundtripped))))))))

;; -- set-status ----------------------------------------------------

(ert-deftest decknix-followup-io-set-status--updates-matching-entry ()
  "Set-status replaces the status cell of the matching id."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open") (title . "a"))
       ((id . "fu-2") (status . "open") (title . "b"))))
    (decknix--agent-review-followup-set-status
     '((id . "fu-2")) "done")
    (let* ((items (decknix--agent-review-followups-read))
           (e1 (seq-find (lambda (e) (string= (alist-get 'id e) "fu-1")) items))
           (e2 (seq-find (lambda (e) (string= (alist-get 'id e) "fu-2")) items)))
      (should (string= "open" (alist-get 'status e1)))
      (should (string= "done" (alist-get 'status e2))))))

(ert-deftest decknix-followup-io-set-status--missing-id-is-noop-on-data ()
  "Set-status against an unknown id leaves every stored entry intact."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open"))))
    (decknix--agent-review-followup-set-status
     '((id . "fu-missing")) "done")
    (let ((items (decknix--agent-review-followups-read)))
      (should (= 1 (length items)))
      (should (string= "open" (alist-get 'status (car items)))))))

(ert-deftest decknix-followup-io-set-status--preserves-other-fields ()
  "Updating status does not mutate sibling alist cells."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open") (title . "keep")
        (workspace . "/tmp/ws") (author . "me"))))
    (decknix--agent-review-followup-set-status
     '((id . "fu-1")) "done")
    (let* ((items (decknix--agent-review-followups-read))
           (entry (car items)))
      (should (string= "done" (alist-get 'status entry)))
      (should (string= "keep" (alist-get 'title entry)))
      (should (string= "/tmp/ws" (alist-get 'workspace entry)))
      (should (string= "me" (alist-get 'author entry))))))

;; -- delete --------------------------------------------------------

(ert-deftest decknix-followup-io-delete--confirmed-removes-matching-entry ()
  "Delete with `yes-or-no-p' confirmed removes the matching id."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open"))
       ((id . "fu-2") (status . "open"))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (decknix--agent-review-followup-delete '((id . "fu-1"))))
    (let ((items (decknix--agent-review-followups-read)))
      (should (= 1 (length items)))
      (should (string= "fu-2" (alist-get 'id (car items)))))))

(ert-deftest decknix-followup-io-delete--declined-leaves-stash-intact ()
  "Delete with `yes-or-no-p' declined is a no-op."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open"))
       ((id . "fu-2") (status . "open"))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (decknix--agent-review-followup-delete '((id . "fu-1"))))
    (let ((items (decknix--agent-review-followups-read)))
      (should (= 2 (length items))))))

(ert-deftest decknix-followup-io-delete--missing-id-confirmed-is-noop-on-data ()
  "Confirmed delete for an unknown id leaves the stash unchanged."
  (decknix-test-with-tmp-followups-file
    (decknix--agent-review-followups-write
     '(((id . "fu-1") (status . "open"))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (decknix--agent-review-followup-delete '((id . "fu-missing"))))
    (let ((items (decknix--agent-review-followups-read)))
      (should (= 1 (length items)))
      (should (string= "fu-1" (alist-get 'id (car items)))))))

(provide 'decknix-agent-review-followup-io-test)
;;; decknix-agent-review-followup-io-test.el ends here
