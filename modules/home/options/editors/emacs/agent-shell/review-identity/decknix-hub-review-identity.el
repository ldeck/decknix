;;; decknix-hub-review-identity.el --- Which PR is a review session on? -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, github, pr, review

;;; Commentary:
;;
;; One question, asked before launching a review: does this PR already
;; have a live review session?  A wrong "no" starts a SECOND agent on a
;; PR that already has one, and both can post to GitHub.
;;
;; That is not hypothetical.  The original check matched buffer names
;; against `pr-<repo>-<number>'.  It held only because a restart killed
;; every review session and they were relaunched under that exact name.
;; Once broker reattach (#151) let them survive instead, they came back
;; named from their TAGS (`auto/#166/oneroof-integration/review'), the
;; needle stopped matching, and six PRs each acquired a second reviewer.
;;
;; The root error was treating a display string as an identity.  Buffer
;; names are renamed on reattach; tags are edited by hand at will --
;; `#291' below has picked up `fix'/`firestore'/`pin'.  Neither is stable
;; enough to decide whether to spawn another agent against a live PR.
;;
;; So the coordinates are recorded at launch and consulted first, with
;; the two mutable signals kept only as fallbacks for sessions that
;; predate the recording:
;;
;;   1. recorded `repo#number'  -- authoritative; survives every rename
;;   2. tags: `#<number>' AND repo, as a SUBSET  -- tolerates additions
;;   3. buffer name: `pr-<repo>-<number>'        -- the legacy convention
;;
;; Both fallbacks are anchored so `#2061' cannot satisfy `#20611'.

;;; Code:

(require 'subr-x)

(defun decknix--hub-review-pr-key (repo number)
  "Return the stable `repo#number' identity for a PR, or nil.

REPO may be a bare name or a full `owner/repo'; only the final segment
is kept, so a session recorded from a full path still matches a hub item
carrying the short form.  NUMBER may be a number or a string."
  (let* ((repo (and (stringp repo) (car (last (split-string repo "/")))))
         (number (cond ((numberp number) (number-to-string number))
                       ((and (stringp number) (not (string-empty-p number))) number))))
    (when (and repo (not (string-empty-p repo)) number)
      (format "%s#%s" repo number))))

(defun decknix--hub-review-pr-key-from-name (name)
  "Extract the `repo#number' identity from a launch NAME, or nil.

NAME is the `pr-<repo>-<number>' string a review launcher constructs from
the PR coordinates it was given.  Reading it back is only sound AT LAUNCH,
which is the one moment it is guaranteed to still be that construction --
the buffer is renamed on reattach, and the point of recording the key is
to outlive exactly that.  Never use this to identify an existing session;
use `decknix--hub-review-session-covers-p'."
  (when (and (stringp name)
             (string-match "\\`pr-\\(.+\\)-\\([0-9]+\\)\\'" name))
    (decknix--hub-review-pr-key (match-string 1 name) (match-string 2 name))))

(defun decknix--hub-review-session-covers-p (repo number buffer-name tags review-pr)
  "Non-nil when a session covers the PR identified by REPO and NUMBER.

REVIEW-PR is the session's recorded `repo#number' (nil for sessions
launched before coordinates were recorded).  BUFFER-NAME and TAGS are
its current display properties.

REVIEW-PR is authoritative when present: it both confirms and DENIES.  A
session recorded against another PR returns nil even if its name or tags
look right, because a renamed buffer must not be credited with covering
a PR it is not on.

Otherwise fall back to tags, then to the legacy name convention.  The
tag test is a subset (`#<number>' AND repo both present) rather than an
equality, so amending a session's tags by hand does not orphan it and
quietly license a duplicate reviewer."
  (let ((key (decknix--hub-review-pr-key repo number)))
    (when key
      (if (and review-pr (stringp review-pr) (not (string-empty-p review-pr)))
          (equal review-pr key)
        (let* ((short (car (last (split-string repo "/"))))
               (num (if (numberp number) (number-to-string number) number)))
          (or
           ;; Tags: both signals required.  A number alone is ambiguous
           ;; across repos, and a repo alone matches every PR in it.
           (and tags (listp tags)
                (member (concat "#" num) tags)
                (member short tags)
                t)
           ;; Legacy buffer-name convention, anchored at the end so
           ;; `pr-upside-206110' does not satisfy `pr-upside-20611'.
           (and (stringp buffer-name)
                (string-match-p
                 (concat "\\(\\`\\|[^-[:alnum:]]\\)"
                         (regexp-quote (format "pr-%s-%s" short num))
                         "\\([^[:alnum:]]\\|\\'\\)")
                 buffer-name)
                t)))))))

(provide 'decknix-hub-review-identity)
;;; decknix-hub-review-identity.el ends here
