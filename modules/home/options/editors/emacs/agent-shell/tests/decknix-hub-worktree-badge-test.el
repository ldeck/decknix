;;; decknix-hub-worktree-badge-test.el --- Row-badge glyph + no-disk contract -*- lexical-binding: t -*-

;; Package-Requires: ((emacs "29.1") (decknix-agent-shell-hub "0.1"))

;;; Commentary:
;;
;; Pins `decknix--hub-worktree-row-badge': (1) the 2-column glyph it
;; returns for each worktree state, and (2) that it performs ZERO
;; filesystem I/O on the render path.  The badge used to call
;; `file-equal-p' (which resolves symlinks via `file-truename') per
;; row every 2 seconds; on a cold iCloud path that blocked input for
;; seconds.  It now compares cached truenames via
;; `decknix--hub-path-equal-p'.  Every case below runs with all disk
;; probes stubbed to signal, so any regression back to a live
;; `file-*' call fails loudly.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-hub-path-facts)
(require 'decknix-agent-shell-hub)

(defmacro decknix-badge-test--case (bindings &rest body)
  "Run BODY with the registry/live stubs in BINDINGS and disk sealed.
BINDINGS is a plist accepting :primary, :find and :live (each a
lambda).  `-canonical-repo' is stubbed to identity.  Every `file-*'
probe signals so the badge is proven disk-free."
  (declare (indent 1))
  `(let ((decknix--hub-path-facts (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'decknix--hub-worktree-canonical-repo)
                (lambda (r) r))
               ((symbol-function 'decknix-hub-worktree-primary)
                (or ,(plist-get bindings :primary) (lambda (_) nil)))
               ((symbol-function 'decknix-hub-worktree-find)
                (or ,(plist-get bindings :find) (lambda (_ _b) nil)))
               ((symbol-function 'decknix--hub-worktree-live-workspaces)
                (or ,(plist-get bindings :live)
                    (lambda () (make-hash-table :test 'equal))))
               ((symbol-function 'file-equal-p)
                (lambda (&rest _) (error "file-equal-p on render path")))
               ((symbol-function 'file-truename)
                (lambda (&rest _) (error "file-truename on render path")))
               ((symbol-function 'file-exists-p)
                (lambda (&rest _) (error "file-exists-p on render path")))
               ((symbol-function 'file-attributes)
                (lambda (&rest _) (error "file-attributes on render path")))
               ((symbol-function 'file-directory-p)
                (lambda (&rest _) (error "file-directory-p on render path"))))
       ,@body)))

(defun decknix-badge-test--fg (s)
  "Return the :foreground of the first glyph in badge string S."
  (let ((face (get-text-property 0 'face s)))
    (plist-get face :foreground)))

(ert-deftest decknix-badge--nil-repo-is-blank ()
  (decknix-badge-test--case ()
    (should (equal "  " (decknix--hub-worktree-row-badge nil "b")))))

(ert-deftest decknix-badge--no-primary-is-down-arrow ()
  (decknix-badge-test--case (:primary (lambda (_) nil))
    (let ((b (decknix--hub-worktree-row-badge "o/r" "b")))
      (should (string-prefix-p "↓" b))
      (should (equal "#5c6370" (decknix-badge-test--fg b))))))

(ert-deftest decknix-badge--no-worktree-is-down-arrow ()
  (decknix-badge-test--case (:primary (lambda (_) "/p") :find (lambda (_ _b) nil))
    (let ((b (decknix--hub-worktree-row-badge "o/r" "b")))
      (should (string-prefix-p "↓" b)))))

(ert-deftest decknix-badge--worktree-equals-primary-is-blank ()
  "The primary checkout itself carries no branch badge (disk-free)."
  (decknix-badge-test--case (:primary (lambda (_) "/p")
                             :find (lambda (_ _b) "/p"))
    (should (equal "  " (decknix--hub-worktree-row-badge "o/r" "main")))))

(ert-deftest decknix-badge--idle-worktree-is-blue ()
  "A separate worktree with no live session renders blue, disk-free."
  (decknix-badge-test--case (:primary (lambda (_) "/p")
                             :find (lambda (_ _b) "/p-wt/feat")
                             :live (lambda () (make-hash-table :test 'equal)))
    (let ((b (decknix--hub-worktree-row-badge "o/r" "feat")))
      (should (string-prefix-p "⎇" b))
      (should (equal "#61afef" (decknix-badge-test--fg b))))))

(ert-deftest decknix-badge--live-worktree-is-green ()
  "A worktree backing a live session renders green, disk-free."
  (decknix-badge-test--case
      (:primary (lambda (_) "/p")
       :find (lambda (_ _b) "/p-wt/feat")
       :live (lambda ()
               (let ((h (make-hash-table :test 'equal)))
                 (puthash (file-name-as-directory
                           (expand-file-name "/p-wt/feat"))
                          t h)
                 h)))
    (let ((b (decknix--hub-worktree-row-badge "o/r" "feat")))
      (should (string-prefix-p "⎇" b))
      (should (equal "#98c379" (decknix-badge-test--fg b))))))

(provide 'decknix-hub-worktree-badge-test)
;;; decknix-hub-worktree-badge-test.el ends here
