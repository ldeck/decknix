;;; decknix-agent-re-review.el --- Re-review routing for re-requested PRs -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, review, decknix

;;; Commentary:
;;
;; When a PR author presses GitHub's "re-request review", the hub daemon
;; emits `re_requested' on the Requests item (see `re_requested' in
;; pkgs/decknix-hub/src/main.rs) and
;; `decknix--hub-requests-reviewed-visible-p' already resurfaces the row
;; past the hide-reviewed filter.  What was missing is what happens next:
;;
;;   1. the resurfaced row looked like any other Request, so a re-review
;;      was indistinguishable from a first-time ask; and
;;   2. opening it started a BRAND NEW review session, throwing away the
;;      context of the review that had already been done -- the agent
;;      re-read the whole PR from scratch and re-derived conclusions it
;;      had already reached.
;;
;; This module carries the pure half of the fix: recognising a re-review
;; item, and deciding WHERE an open-review action should land.  The
;; routing is a three-way choice, preferring the most context-rich
;; target available:
;;
;;   live   -- a review buffer for this PR is still open; reuse it.
;;   saved  -- no live buffer, but a previous session for this PR was
;;             snapshotted; resume that.
;;   fresh  -- nothing to reuse; start a new review session.
;;
;; Session identity is the `pr-<repo>-<number>' needle minted by
;; `decknix-agent-review-pr' -- it names the live buffer and appears in
;; the saved entry's derived name, and the same PR number + repo also
;; land in the session tags ("review" REPO "#NUMBER"), so a saved entry
;; is matched on either.
;;
;; The IO half (submitting the prompt, resuming the snapshot, painting
;; the row) lives at the call sites; everything here is pure so it is
;; ERT-covered without a running agent.
;;
;; Public surface:
;;
;;   `decknix-agent-re-review-prompt'      -- the prompt text
;;   `decknix-agent-re-review-item-p'      -- item -> bool
;;   `decknix-agent-re-review-needle'      -- repo/number -> "pr-repo-num"
;;   `decknix-agent-re-review-find-live'   -- needle, buffers -> buffer
;;   `decknix-agent-re-review-find-saved'  -- needle, entries -> entry
;;   `decknix-agent-re-review-target'      -- the three-way route

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom decknix-agent-re-review-prompt
  "The pr has been updated; please re-review"
  "Prompt sent to a reused review session when a PR is re-requested.
Sent verbatim, so it reads as the user's own follow-up turn rather
than as a fresh `/review-service-pr' invocation -- the point of
reusing the session is that the agent still holds the prior review."
  :type 'string
  :group 'decknix)

(defun decknix-agent-re-review-item-p (item)
  "Return non-nil when hub Requests ITEM is a genuine re-review.

ITEM is an alist as delivered by the hub daemon.  `re_requested' is
emitted as `directly_requested AND my_review.is_some()' -- I reviewed
it once and the author has asked me again -- which is exactly the
case where reusing the earlier session beats starting over.

Compared with `eq' against t so a JSON `false' (or the `nil' that
older hub data yields for the field) reads as \"not a re-review\"
rather than merely absent."
  (eq (alist-get 're_requested item) t))

(defun decknix-agent-re-review-needle (repo number)
  "Return the `pr-REPO-NUMBER' session needle, or nil if unresolvable.

REPO may be a full \"owner/repo\" -- only the trailing segment is
used, matching `decknix-agent-review-pr' when it mints the session
name and `decknix--hub-request-has-live-session-p' when it looks one
up.  NUMBER may be a number or a numeric string."
  (let* ((repo-full (or repo ""))
         (short (car (last (split-string repo-full "/" t))))
         (num (cond ((numberp number) (number-to-string number))
                    ((and (stringp number) (not (string-empty-p number))) number))))
    (when (and short (not (string-empty-p short)) num)
      (format "pr-%s-%s" short num))))

(defun decknix-agent-re-review-find-live (needle buffers)
  "Return the first live buffer in BUFFERS whose name carries NEEDLE.

Substring rather than exact match: agent-shell decorates a session
buffer name with provider / status chrome around the base name, so
`pr-foo-12' is embedded rather than standing alone.  Dead buffers are
skipped so a stale entry never wins over a live one."
  (when (and needle buffers)
    (seq-find (lambda (buf)
                (and (buffer-live-p buf)
                     (string-match-p (regexp-quote needle) (buffer-name buf))))
              buffers)))

(defun decknix-agent-re-review--entry-matches-p (needle number entry)
  "Return non-nil when saved ENTRY belongs to NEEDLE's PR.

Matches on the derived name (which embeds the needle) or on the
session tags, which `decknix-agent-review-pr' seeds as
\(\"review\" REPO \"#NUMBER\").  The tag route is the more durable of
the two -- a user may rename a session, but the tags are metadata."
  (let ((name (alist-get 'name entry))
        (tags (alist-get 'tags entry)))
    (or (and (stringp name) needle
             (string-match-p (regexp-quote needle) name))
        (and number tags
             (member "review" tags)
             (member (format "#%s" number) tags)
             t))))

(defun decknix-agent-re-review-find-saved (needle number entries)
  "Return the first entry in ENTRIES matching NEEDLE / NUMBER, else nil.

ENTRIES are `decknix--sidebar-previous-sessions' alists (session-id,
name, workspace, conv-key, tags).  The list is newest-first, so the
first match is the most recent session for that PR."
  (when entries
    (seq-find (lambda (e)
                (decknix-agent-re-review--entry-matches-p needle number e))
              entries)))

(defun decknix-agent-re-review-target (needle number buffers entries)
  "Decide where an open-review action for NEEDLE should land.

Returns a cons whose car is the route and whose cdr is the payload:

  (live  . BUFFER)  -- reuse this open review buffer
  (saved . ENTRY)   -- resume this snapshotted session
  (fresh)           -- nothing to reuse; start a new review

Live beats saved beats fresh: an open buffer holds the most context
and reusing it costs nothing, whereas a resume replays a transcript
and a fresh start discards the prior review entirely."
  (let ((live (decknix-agent-re-review-find-live needle buffers)))
    (if live
        (cons 'live live)
      (let ((saved (decknix-agent-re-review-find-saved needle number entries)))
        (if saved
            (cons 'saved saved)
          (list 'fresh))))))

;; -- IO half --------------------------------------------------------
;; Forward declarations for symbols owned by sibling packages / the
;; heredoc, all loaded before this module is exercised.  Declared (not
;; `require'd) so byte-compile stays warning-clean without dragging the
;; whole session/sidebar surface into this package's closure.
(declare-function agent-shell-buffers "ext:agent-shell" ())
(declare-function shell-maker-submit "ext:shell-maker" (&rest args))
(declare-function decknix--agent-parse-pr-url
                  "decknix-agent-shell-main" (url))
(declare-function decknix-agent-review-pr
                  "decknix-agent-shell-main" (url))
(declare-function decknix--compose-enqueue-prompt
                  "decknix-agent-shell-main" (target content))
(declare-function decknix--sidebar-restore-previous-session
                  "decknix-agent-shell-workspace" (entry &optional focus))
(defvar decknix--sidebar-previous-sessions)

(defcustom decknix-agent-re-review-resume-poll-interval 0.4
  "Seconds between polls for a resumed review buffer to appear."
  :type 'number
  :group 'decknix)

(defcustom decknix-agent-re-review-resume-poll-tries 25
  "How many times to poll for a resumed review buffer before giving up.
With the default interval this is a ~10s budget, which covers a cold
agent start.  On expiry the session is left open and un-prompted
rather than the prompt being sent somewhere unintended."
  :type 'integer
  :group 'decknix)

(defun decknix-agent-re-review-send (target content)
  "Submit CONTENT into TARGET, queueing when the agent is busy.

Mirrors `decknix--agent-review-submit-to-agent' but without its
interactive busy prompt: a re-review is dispatched from a sidebar
row, where a `read-char-choice' would be a surprise.  A busy agent
gets the prompt queued instead, so the ask is never silently lost."
  (when (buffer-live-p target)
    (if (and (with-current-buffer target (bound-and-true-p shell-maker--busy))
             (fboundp 'decknix--compose-enqueue-prompt))
        (progn
          (decknix--compose-enqueue-prompt target content)
          (message "Agent busy — queued re-review for %s" (buffer-name target)))
      (with-current-buffer target
        (goto-char (point-max))
        (shell-maker-submit :input content))
      (message "Re-review sent to %s" (buffer-name target)))
    (pop-to-buffer target)
    target))

(defun decknix-agent-re-review--send-when-ready (needle content &optional tries)
  "Poll for NEEDLE's buffer, then send CONTENT into it.

A resume creates its buffer asynchronously, so the buffer does not
exist at the moment `decknix--sidebar-restore-previous-session'
returns.  Rather than guess a fixed delay, poll on a timer and send
as soon as the buffer shows up."
  (let ((tries (or tries decknix-agent-re-review-resume-poll-tries)))
    (if-let ((buf (decknix-agent-re-review-find-live
                   needle (and (fboundp 'agent-shell-buffers)
                               (agent-shell-buffers)))))
        (decknix-agent-re-review-send buf content)
      (if (<= tries 0)
          (message "decknix: resumed session for %s did not appear; not prompting"
                   needle)
        (run-at-time decknix-agent-re-review-resume-poll-interval nil
                     #'decknix-agent-re-review--send-when-ready
                     needle content (1- tries))))))

;;;###autoload
(defun decknix-agent-re-review-pr (url)
  "Open the review for URL, reusing the earlier review session if there is one.

The point of a re-review is that a review already happened: the
agent that did it still holds the PR's context, the reviewer's own
conclusions, and whatever the bots argued about.  Starting fresh
throws all of that away and re-derives it at full cost, so this
routes to the richest target available (see
`decknix-agent-re-review-target'):

  live  -- the review buffer is still open: prompt it directly.
  saved -- resume the snapshotted session, then prompt it once its
           buffer appears.
  fresh -- nothing to reuse: fall through to `decknix-agent-review-pr',
           which starts a normal first-time review.

The prompt is `decknix-agent-re-review-prompt'."
  (interactive
   (list (read-string "PR URL: " (and (fboundp 'decknix--agent-clipboard-url)
                                      (decknix--agent-clipboard-url)))))
  (let ((parsed (decknix--agent-parse-pr-url url)))
    (unless parsed
      (user-error "Not a valid GitHub PR URL: %s" url))
    (let* ((repo (alist-get 'repo parsed))
           (number (alist-get 'number parsed))
           (needle (decknix-agent-re-review-needle repo number))
           (route (decknix-agent-re-review-target
                   needle number
                   (and (fboundp 'agent-shell-buffers) (agent-shell-buffers))
                   (and (boundp 'decknix--sidebar-previous-sessions)
                        decknix--sidebar-previous-sessions))))
      (pcase (car route)
        ('live
         (decknix-agent-re-review-send (cdr route) decknix-agent-re-review-prompt))
        ('saved
         (decknix--sidebar-restore-previous-session (cdr route) t)
         (decknix-agent-re-review--send-when-ready
          needle decknix-agent-re-review-prompt)
         (message "Resuming saved review session for %s…" needle))
        (_
         (message "No earlier review session for %s — starting a fresh review" needle)
         (decknix-agent-review-pr url))))))

(provide 'decknix-agent-re-review)
;;; decknix-agent-re-review.el ends here
