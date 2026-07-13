;;; decknix-agent-shell-main-review.el --- Inline review buffer mode -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Inline review buffer (`decknix-agent-review-mode').  Captures an
;; agent-shell exchange into a dedicated markdown buffer where you
;; can annotate with Option-1 preamble style (> ✅ approved, > ❌
;; reject, > 🔀 option B, > 💬 comment).  Annotations are routed
;; back to the source session (or to Jira / a PR-comment / a file)
;; via `C-c C-c'.
;;
;; PR Split.S.1: split out of `decknix-agent-shell-main' so the
;; ~3700-line bulk file can be navigated by theme.  Co-resident
;; with the main file in `main-bulk/' so it picks up the same
;; trivialBuild + load-path semantics; the byte-compiler resolves
;; `(require 'decknix-agent-shell-main-review)` against the sibling
;; .el at compile time.  Side-effecting `(define-key)` calls into
;; the heredoc's prefix maps still happen in the heredoc itself
;; (per AGENTS.md Rule 2); this file owns the mode definition,
;; the buffer-local state, and the interactive commands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Forward declarations for symbols defined in carved review/
;; packages, in `decknix-agent-shell-main', or in external Emacs
;; modules.  Resolved at runtime via the heredoc's `(require ...)'
;; chain in `default.el'.
(declare-function markdown-mode "ext:markdown-mode")
(declare-function yas-minor-mode "ext:yasnippet")
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup" (&optional buf))
(declare-function decknix--agent-review-author
                  "decknix-agent-review-collaborators")
(declare-function decknix--agent-review-load-collaborators
                  "decknix-agent-review-collaborators")
(declare-function decknix--agent-review-save-collaborators
                  "decknix-agent-review-collaborators")
(declare-function decknix--agent-review-capture-exchange
                  "decknix-agent-review-capture" (source-buffer n))
(declare-function decknix--agent-review-render-preamble
                  "decknix-agent-review-format"
                  (session-name workspace collaborators))
(declare-function decknix--agent-review-format-exchanges
                  "decknix-agent-review-format" (exchanges))
(declare-function decknix--agent-review-content-for-route
                  "decknix-agent-review-submit" (route))
(declare-function decknix--agent-review-submit-to-agent
                  "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-submit-pr
                  "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-submit-jira
                  "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-submit-file
                  "decknix-agent-review-submit" (content))
(declare-function decknix--agent-review-followups-read
                  "decknix-agent-review-followup-io" ())
(declare-function decknix--agent-review-followups-write
                  "decknix-agent-review-followup-io" (items))
(declare-function decknix--agent-review-followup-set-status
                  "decknix-agent-review-followup-io" (entry status))
(declare-function decknix--agent-review-followup-delete
                  "decknix-agent-review-followup-io" (entry))
(declare-function decknix--agent-review-followup-id
                  "decknix-agent-review-followup-format")
(declare-function decknix--agent-review-followup-describe
                  "decknix-agent-review-followup-format" (entry))

;; Forward defvars for heredoc-resident state and external configs.
(defvar decknix-agent-review-author)
(defvar decknix-agent-review-collaborators)
(defvar decknix-agent-review-collaborators-file)
(defvar decknix-agent-review-followups-file)
(defvar decknix-agent-review-jira-drafts-dir)
(defvar decknix--agent-session-workspace)


;; -- Buffer-local state --

(defvar-local decknix--agent-review-source-buffer nil
  "Agent-shell buffer that this review buffer was created from.")

(defvar-local decknix--agent-review-session-id nil
  "Auggie session-id captured at the time of review.")

(defvar-local decknix--agent-review-workspace nil
  "Workspace root captured from the source buffer.")

(defvar decknix-agent-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'decknix-agent-review-submit)
    (define-key map (kbd "C-c C-k") #'decknix-agent-review-cancel)
    (define-key map (kbd "C-c C-f") #'decknix-agent-review-flag-followup)
    (define-key map (kbd "C-c C-l") #'decknix-agent-review-list-followups)
    (define-key map (kbd "C-c C-m") #'decknix-agent-review-add-collaborator)
    map)
  "Keymap for `decknix-agent-review-mode'.")

(define-derived-mode decknix-agent-review-mode markdown-mode "AgentReview"
  "Major mode for annotating agent-shell exchanges.
Supports inline Option-1 annotations (💬 ✅ ❌ 🔀 🚩) and routing
the review back to the source agent-shell session.
\\{decknix-agent-review-mode-map}"
  (setq-local fill-column 100)
  (setq-local truncate-lines nil)
  ;; Redisplay perf: quoted exchanges are LTR and can be long — force LTR
  ;; + skip bidi bracket-pair resolution (see agent-shell-mode-hook).
  (setq-local bidi-paragraph-direction 'left-to-right)
  (setq-local bidi-inhibit-bpa t)
  (visual-line-mode 1)
  (when (fboundp 'yas-minor-mode)
    (yas-minor-mode 1))
  (decknix--agent-review-load-collaborators))

;; `decknix--agent-review-quote' lives in
;; agent-shell/review/decknix-agent-review-format.el alongside
;; format-exchanges and strip-meta — required at the top of
;; the heredoc.

;; PR B.73: `decknix--agent-review-capture-exchange' was carved
;; into `decknix-agent-review-capture'.  The interactive
;; `decknix-agent-review' entry point (and its review-mode
;; setup) stays here per AGENTS.md Rule 2.

;; `decknix--agent-review-render-preamble' lives in
;; agent-shell/review/decknix-agent-review-format.el (PR B.59) --
;; required at the top of the heredoc.  Its signature takes plain
;; data (SESSION-NAME WORKSPACE COLLABORATORS) so the carved
;; version stays pure; the call site below extracts the buffer-
;; local workspace + author/collaborators list before invoking it.

;; `decknix--agent-review-format-exchanges' lives in
;; agent-shell/review/decknix-agent-review-format.el.

(defun decknix-agent-review (&optional all)
  "Open a review buffer for the current agent-shell session.
With prefix ALL, capture the full session history rather than just
the last exchange."
  (interactive "P")
  (unless (decknix--agent-buffer-session-id)
    (user-error "Not in an agent-shell buffer with a known session"))
  (let* ((src (current-buffer))
         (n (if all 20 1))
         (exchanges (decknix--agent-review-capture-exchange src n))
         (sid (decknix--agent-buffer-session-id))
         (ws (or decknix--agent-session-workspace default-directory))
         (buf-name (format "*agent-review: %s*" (buffer-name src)))
         (buf (get-buffer-create buf-name)))
    (unless exchanges
      (user-error "No exchanges found for this session yet"))
    (with-current-buffer buf
      (decknix-agent-review-mode)
      (setq decknix--agent-review-source-buffer src)
      (setq decknix--agent-review-session-id sid)
      (setq decknix--agent-review-workspace ws)
      (let* ((inhibit-read-only t)
             ;; Extract preamble inputs at the call site so the
             ;; carved formatter (PR B.59) stays pure: buffer name,
             ;; workspace via `or `decknix--agent-session-workspace'
             ;; default-directory'', and author-first collaborators.
             (session-name (buffer-name src))
             (preamble-ws (with-current-buffer src
                            (or decknix--agent-session-workspace
                                default-directory)))
             (author (decknix--agent-review-author))
             (collabs (cons author
                            (seq-remove
                             (lambda (c) (string= c author))
                             decknix-agent-review-collaborators))))
        (erase-buffer)
        (insert (decknix--agent-review-render-preamble
                 session-name preamble-ws collabs))
        (insert (decknix--agent-review-format-exchanges exchanges))
        (goto-char (point-min))
        (when (re-search-forward "^## annotations" nil t)
          (forward-line 2))))
    (pop-to-buffer buf)))


;; -- Submit / route --
;;
;; The defvar `decknix-agent-review-jira-drafts-dir' and the five
;; route helpers (`-content-for-route', `-submit-to-agent',
;; `-submit-pr', `-submit-jira', `-submit-file') live in
;; agent-shell/review/decknix-agent-review-submit.el (PR B.62) --
;; required at the top of the heredoc.  The interactive entry
;; point below stays here next to its `C-c C-c' binding in
;; review-mode.

(cl-defun decknix-agent-review-submit ()
  "Route the review buffer to the configured destination.
Prompts for:
  a  agent      — send as new prompt to source agent-shell (default)
  p  pr-comment — copy to kill-ring for pasting into a PR review
  j  jira       — save as a draft markdown under
          `decknix-agent-review-jira-drafts-dir'
  f  file       — save to a user-chosen path
  q  cancel"
  (interactive)
  (unless (derived-mode-p 'decknix-agent-review-mode)
    (user-error "Not in a review buffer"))
  (let* ((choice (read-char-choice
                  "Route: [a]gent  [p]r-comment  [j]ira  [f]ile  [q]uit "
                  '(?a ?p ?j ?f ?q ?\r)))
         (route (pcase choice
                  ((or ?a ?\r) 'agent)
                  (?p 'pr)
                  (?j 'jira)
                  (?f 'file)
                  (?q nil))))
    (unless route
      (user-error "Cancelled"))
    (let ((content (decknix--agent-review-content-for-route route)))
      (pcase route
        ('agent (decknix--agent-review-submit-to-agent content))
        ('pr    (decknix--agent-review-submit-pr content))
        ('jira  (decknix--agent-review-submit-jira content))
        ('file  (decknix--agent-review-submit-file content))))))

(defun decknix-agent-review-cancel ()
  "Abandon the current review buffer."
  (interactive)
  (when (yes-or-no-p "Abandon this review buffer? ")
    (kill-buffer (current-buffer))))

;; -- Follow-up stash (local JSON; future: GitHub / Jira routes) --
;;
;; The four storage helpers (`decknix-agent-review-followups-file',
;; `-followups-read', `-followups-write', `-followup-set-status',
;; `-followup-delete') live in
;; agent-shell/review/decknix-agent-review-followup-io.el (PR B.61).
;; The two pure formatters (`-followup-id', `-followup-describe')
;; live in agent-shell/review/decknix-agent-review-followup-format.el
;; (PR B.60).  Both packages are required at the top of the heredoc
;; alongside the rest of the review/ cluster.  The interactive
;; commands that compose them (`-flag-followup', `-list-followups')
;; remain here next to the rest of `decknix-agent-review-mode'.

(defun decknix-agent-review-flag-followup (title)
  "Flag the current paragraph as a follow-up.
Records an entry in `decknix-agent-review-followups-file' and
inserts a 🚩 annotation at point referencing its id.  TITLE is
prompted for — defaults to the first non-blank line near point."
  (interactive
   (list
    (let* ((default
            (save-excursion
              (goto-char (line-beginning-position))
              (when (looking-at "[[:space:]]*$")
                (forward-line 1))
              (string-trim
               (buffer-substring-no-properties
                (line-beginning-position)
                (line-end-position))))))
      (read-string (if (and default (not (string-empty-p default)))
                       (format "Follow-up title [%s]: " default)
                     "Follow-up title: ")
                   nil nil default))))
  (when (or (null title) (string-empty-p (string-trim title)))
    (user-error "Empty title — nothing recorded"))
  (let* ((items (decknix--agent-review-followups-read))
         (id (decknix--agent-review-followup-id))
         (entry `((id . ,id)
                  (ts . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                  (session . ,(or (and (buffer-live-p
                                        decknix--agent-review-source-buffer)
                                       (buffer-name
                                        decknix--agent-review-source-buffer))
                                  ""))
                  (workspace . ,(or decknix--agent-review-workspace ""))
                  (author . ,(decknix--agent-review-author))
                  (title . ,(string-trim title))
                  (body . "")
                  (route . "local")
                  (status . "open"))))
    (decknix--agent-review-followups-write (append items (list entry)))
    ;; Insert a linked annotation at point so the review buffer
    ;; shows where the follow-up came from.
    (save-excursion
      (end-of-line)
      (insert (format "\n> 🚩 **%s:** follow-up [%s] — %s\n"
                      (decknix--agent-review-author)
                      id
                      (string-trim title))))
    (message "Recorded follow-up %s — %s" id title)))

;; `decknix--agent-review-followup-describe' lives in
;; agent-shell/review/decknix-agent-review-followup-format.el (PR B.60).

(defun decknix-agent-review-list-followups ()
  "List stashed follow-ups via `completing-read'.
Selecting an entry offers a sub-action: mark-done / re-open / delete
/ copy-id / cancel."
  (interactive)
  (let* ((items (decknix--agent-review-followups-read)))
    (unless items
      (user-error "No follow-ups recorded yet"))
    (let* ((candidates
            (mapcar (lambda (e)
                      (cons (decknix--agent-review-followup-describe e)
                            e))
                    items))
           (pick (completing-read "Follow-up: " candidates nil t))
           (entry (cdr (assoc pick candidates)))
           (action (read-char-choice
                    "[d]one  [o]pen  [x]delete  [c]opy id  [q]uit: "
                    '(?d ?o ?x ?c ?q))))
      (pcase action
        (?d (decknix--agent-review-followup-set-status entry "done"))
        (?o (decknix--agent-review-followup-set-status entry "open"))
        (?x (decknix--agent-review-followup-delete entry))
        (?c (let ((id (alist-get 'id entry)))
              (kill-new id)
              (message "Copied: %s" id)))
        (?q (message "Cancelled"))))))

;; `decknix--agent-review-followup-set-status' and
;; `decknix--agent-review-followup-delete' live in
;; agent-shell/review/decknix-agent-review-followup-io.el (PR B.61).

(defun decknix-agent-review-add-collaborator ()
  "Add a collaborator to the local mention list."
  (interactive)
  (let ((name (read-string "Collaborator name: ")))
    (when (and name (not (string-empty-p name)))
      (cl-pushnew name decknix-agent-review-collaborators
                  :test #'string=)
      (decknix--agent-review-save-collaborators)
      (message "Added collaborator: %s" name))))

(defun decknix--agent-review-read-collaborator ()
  "Prompt for a collaborator name and persist any new entry.
Used by the `,m' yasnippet to populate the mention field.  Returns
the chosen name, or falls back to the review author when cancelled.
Selecting `new…' prompts for a fresh name and adds it to the list."
  (decknix--agent-review-load-collaborators)
  (let* ((author (decknix--agent-review-author))
         (others (seq-remove (lambda (c) (string= c author))
                             decknix-agent-review-collaborators))
         (choice (completing-read
                  "Mention: "
                  (append others (list "new…"))
                  nil nil)))
    (cond
     ((or (null choice) (string-empty-p choice))
      author)
     ((string= choice "new…")
      (let ((new (string-trim
                  (read-string "New collaborator name: "))))
        (if (string-empty-p new)
            author
          (cl-pushnew new decknix-agent-review-collaborators
                      :test #'string=)
          (decknix--agent-review-save-collaborators)
          new)))
     (t
      (unless (member choice decknix-agent-review-collaborators)
        (cl-pushnew choice decknix-agent-review-collaborators
                    :test #'string=)
        (decknix--agent-review-save-collaborators))
      choice))))

(provide 'decknix-agent-shell-main-review)
;;; decknix-agent-shell-main-review.el ends here
