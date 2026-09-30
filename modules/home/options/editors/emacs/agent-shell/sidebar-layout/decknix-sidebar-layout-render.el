;;; decknix-sidebar-layout-render.el --- Session-first sidebar render -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-sidebar-layout "0.1"))
;; Keywords: agent, hub, sidebar

;;; Commentary:
;;
;; Side-effecting half of `decknix-sidebar-layout': the Reviews and WIP
;; sections, their expansion state, and the row properties the actions read.
;;
;; Gated on `decknix-sidebar-layout-enable'.  With it nil the sidebar renders
;; exactly as before, because this replaces three established sections
;; (Requests, WIP, Live) at once and a single variable is a cheaper rollback
;; than a revert.

;;; Code:

(require 'decknix-sidebar-layout)
(require 'seq)

(declare-function decknix--hub-review-session-snapshot "decknix-agent-shell-hub" ())
(declare-function decknix--hub-requests-attention-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-reviewed-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-draft-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function decknix--hub-requests-conflict-visible-p
                  "decknix-hub-attention-filter" (item))
(declare-function agent-shell-workspace-sidebar-refresh "agent-shell-workspace" ())

(defvar decknix-sidebar-layout-enable t
  "When non-nil, render the session-first Reviews/WIP/Unattached sections.
Set nil to fall back to the previous Requests/WIP/Live layout.")

(defvar decknix--layout-expanded (make-hash-table :test 'equal)
  "Repo -> non-nil when its Reviews group is expanded.")

(defvar decknix--layout-state-file
  (expand-file-name "~/.config/decknix/hub/sidebar-layout.el")
  "Where expansion state is persisted across restarts.")

(declare-function decknix--sidebar-render-section-header
                  "decknix-sidebar-format" (title &optional section-id))

(defun decknix--layout-save-state ()
  "Persist which groups are expanded."
  (ignore-errors
    (let ((repos nil))
      (maphash (lambda (k v) (when v (push k repos))) decknix--layout-expanded)
      (with-temp-file decknix--layout-state-file
        (prin1 (sort repos #'string<) (current-buffer))))))

(defun decknix--layout-load-state ()
  "Restore expansion state, if any was saved."
  (ignore-errors
    (when (file-readable-p decknix--layout-state-file)
      (let ((repos (with-temp-buffer
                     (insert-file-contents decknix--layout-state-file)
                     (read (current-buffer)))))
        (clrhash decknix--layout-expanded)
        (dolist (r repos) (puthash r t decknix--layout-expanded))))))

(defun decknix--layout-expanded-p (repo)
  "Return non-nil when REPO's group is expanded."
  (gethash repo decknix--layout-expanded))

(defun decknix-layout-toggle-expand ()
  "Expand or collapse the Reviews group on this row."
  (interactive)
  (let ((repo (get-text-property (line-beginning-position) 'decknix-layout-repo)))
    (unless repo (user-error "Not on a Reviews group row"))
    (if (decknix--layout-expanded-p repo)
        (remhash repo decknix--layout-expanded)
      (puthash repo t decknix--layout-expanded))
    (decknix--layout-save-state)
    (when (fboundp 'agent-shell-workspace-sidebar-refresh)
      (agent-shell-workspace-sidebar-refresh))))

(defun decknix--layout-sessions ()
  "Return the live session snapshot, or nil."
  (and (fboundp 'decknix--hub-review-session-snapshot)
       (ignore-errors (decknix--hub-review-session-snapshot))))

(defvar decknix--hub-reviews)

(defun decknix--layout-feed-items ()
  "Return the hub's request items, or nil.

Reads the same `decknix--hub-reviews' the old Requests render used, and
applies the SAME visibility filters -- otherwise folding Requests into
Reviews would quietly re-show every draft, conflicted and already-reviewed
PR those filters exist to hide."
  (let ((items (and (boundp 'decknix--hub-reviews)
                    (alist-get 'items decknix--hub-reviews))))
    (if (fboundp 'decknix--hub-requests-attention-visible-p)
        (seq-filter
         (lambda (item)
           (and (decknix--hub-requests-attention-visible-p item)
                (decknix--hub-requests-reviewed-visible-p item)
                (decknix--hub-requests-draft-visible-p item)
                (decknix--hub-requests-conflict-visible-p item)))
         items)
      items)))

(defun decknix--layout-short-name (buffer-name)
  "Return BUFFER-NAME without the agent wrapper."
  (replace-regexp-in-string
   "\\`\\*\\(Claude\\|Pi\\|Auggie\\|Codex\\|Gemini\\)?:? ?\\|\\*\\'" ""
   (or buffer-name "")))

(defun decknix--layout-render-reviews (line-num width)
  "Render the Reviews section.  Returns the updated LINE-NUM."
  (let* ((sessions (decknix--layout-sessions))
         (items (decknix--layout-feed-items))
         (groups (decknix--layout-review-groups sessions items))
         (dups (decknix--layout-duplicate-prs sessions))
         (total (apply #'+ (mapcar (lambda (g) (or (plist-get g :sessions) 0)) groups)))
         (asking (apply #'+ (mapcar (lambda (g) (or (plist-get g :asking) 0)) groups))))
    (when groups
      (decknix--sidebar-render-section-header
       (if (> asking 0)
           (format "Reviews (%d) — %d need you" total asking)
         (format "Reviews (%d)" total))
       'reviews)
      (setq line-num (1+ line-num))
      (dolist (group groups)
        (let ((repo (plist-get group :repo)))
          (insert (propertize (decknix--layout-group-label group width)
                              'face (if (> (or (plist-get group :asking) 0) 0)
                                        'warning 'default)
                              'decknix-layout-repo repo
                              'decknix-layout-group group)
                  "\n")
          (setq line-num (1+ line-num))
          (when (decknix--layout-expanded-p repo)
            (dolist (pr (plist-get group :prs))
              (insert (propertize (decknix--layout-pr-label pr)
                                  'face (if (decknix--layout-attention-p
                                             (plist-get pr :state))
                                            'warning 'font-lock-comment-face)
                                  'decknix-layout-pr pr
                                  'decknix-hub-type 'request
                                  'decknix-hub-repo (alist-get 'repo (plist-get pr :item))
                                  'decknix-hub-number (plist-get pr :number)
                                  'decknix-hub-url (alist-get 'url (plist-get pr :item)))
                      "\n")
              (setq line-num (1+ line-num))))))
      (when dups
        (insert (propertize (format " ⚠  %d PRs have 2+ sessions" (length dups))
                            'face 'error
                            'decknix-layout-duplicates dups)
                "\n")
        (setq line-num (1+ line-num)))))
  line-num)

(defun decknix--layout-render-wip (line-num width)
  "Render the WIP section: sessions I started.  Returns updated LINE-NUM."
  (let ((wip (decknix--layout-wip-sessions (decknix--layout-sessions))))
    (when wip
      (insert "\n")
      (setq line-num (1+ line-num))
      (decknix--sidebar-render-section-header
       (format "WIP (%d)" (length wip)) 'wip-sessions)
      (setq line-num (1+ line-num))
      (dolist (session wip)
        (let* ((state (nth 3 session))
               (name (decknix--layout-short-name (nth 0 session)))
               (left (format " %s  %s" (decknix--layout-state-glyph state) name))
               (right (or state ""))
               (pad (max 1 (- width (string-width left) (string-width right)))))
          (insert (propertize (concat left (make-string pad ?\s) right)
                              'face (if (decknix--layout-attention-p state)
                                        'warning 'default)
                              'decknix-layout-session session
                              'decknix-layout-buffer (nth 0 session))
                  "\n")
          (setq line-num (1+ line-num))))))
  line-num)

(provide 'decknix-sidebar-layout-render)
;;; decknix-sidebar-layout-render.el ends here
