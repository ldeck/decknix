;;; decknix-agent-review-collaborators.el --- Review @mention author + collaborators store -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, review, persistence, decknix

;;; Commentary:
;;
;; Persistence + identity primitives for the inline review buffer
;; carved out of `decknix-agent-shell-main' (main-bulk) into the
;; existing `agent-shell/review/' cluster (sibling of
;; `decknix-agent-review-format').  Owns the three user-facing
;; defvars + three pure-ish accessors that back the
;; `decknix-agent-review-mode' @mention picker and annotation
;; snippets advertised by the heredoc yasnippet block.
;;
;; Three defvars + three defuns:
;;
;;   `decknix-agent-review-author'
;;       Optional override for the annotation author name.
;;       Falls back to `user-login-name' then "me".
;;
;;   `decknix-agent-review-collaborators'
;;       In-memory list of strings used by the @mention picker.
;;       Populated on demand and persisted to disk.
;;
;;   `decknix-agent-review-collaborators-file'
;;       Path to the persisted store
;;       (~/.config/decknix/review-collaborators.el).
;;
;;   `decknix--agent-review-author'
;;       Returns the annotation author -- override, then
;;       `user-login-name', then literal "me".
;;
;;   `decknix--agent-review-load-collaborators'
;;       Reads the persisted file via `read' and assigns into
;;       `decknix-agent-review-collaborators'.  No-op when the
;;       file is missing; swallows read errors so a corrupt
;;       file does not break review-mode init.
;;
;;   `decknix--agent-review-save-collaborators'
;;       Persists `decknix-agent-review-collaborators' via
;;       `prin1' inside `with-temp-file', creating the parent
;;       directory if needed.

;;; Code:

(defvar decknix-agent-review-author nil
  "Name used to author annotations in the review buffer.
When nil, defaults to `user-login-name'.")

(defvar decknix-agent-review-collaborators '()
  "Collaborators available in the review buffer's @mention picker.
Populated on demand; persisted to
`decknix-agent-review-collaborators-file'.")

(defvar decknix-agent-review-collaborators-file
  (expand-file-name "~/.config/decknix/review-collaborators.el")
  "File used to persist known collaborators across Emacs sessions.")

(defun decknix--agent-review-author ()
  "Return the annotation author name."
  (or decknix-agent-review-author user-login-name "me"))

(defun decknix--agent-review-load-collaborators ()
  "Read persisted collaborators into `decknix-agent-review-collaborators'."
  (let ((f decknix-agent-review-collaborators-file))
    (when (file-exists-p f)
      (condition-case nil
          (let ((data (with-temp-buffer
                        (insert-file-contents f)
                        (read (current-buffer)))))
            (when (listp data)
              (setq decknix-agent-review-collaborators data)))
        (error nil)))))

(defun decknix--agent-review-save-collaborators ()
  "Persist `decknix-agent-review-collaborators' to disk."
  (let ((f decknix-agent-review-collaborators-file))
    (make-directory (file-name-directory f) t)
    (with-temp-file f
      (prin1 decknix-agent-review-collaborators (current-buffer)))))

(provide 'decknix-agent-review-collaborators)
;;; decknix-agent-review-collaborators.el ends here
