;;; decknix-agent-resourcing-ui.el --- C-c s a resourcing view -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-resourcing "0.1"))
;; Keywords: agent, agent-shell, decknix, resourcing

;;; Commentary:
;;
;; Display + orchestration for the `C-c s a' resourcing view (#145, agent
;; resourcing Feature 2).  Collects the current conversation's resources
;; from the live buffer-locals, link store, sub-agent walk and the global
;; hub data, feeds them through the pure `decknix-agent-resourcing'
;; aggregator, and renders the resulting category tree into a read-only
;; `*Agent Resources*' buffer (modelled on `decknix-priority').
;;
;; The pure aggregation + attention rollup live in
;; `decknix-agent-resourcing'; this module only does I/O and rendering, so
;; it reads the hub globals defensively via `bound-and-true-p' (they are
;; absent when the hub is disabled) and forward-declares the session /
;; link-store accessors resolved at runtime from the heredoc.

;;; Code:

(require 'decknix-agent-resourcing)

;; Live accessors, resolved at runtime (heredoc load order).
(declare-function decknix--agent-current-conv-key "ext:decknix-agent-shell-main")
(declare-function decknix--agent-buffer-session-id
                  "decknix-agent-buffer-lookup" (&optional buf))
(declare-function decknix--agent-linked-prs "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-linked-repos "decknix-agent-link-store" (conv-key))
(declare-function decknix--agent-session-subagents
                  "decknix-agent-session-history" (session-id &optional provider-id))
(defvar decknix--agent-provider-id)
(defvar decknix--hub-reviews)
(defvar decknix--hub-wip)

(defconst decknix-agent-resourcing-buffer-name "*Agent Resources*"
  "Name of the resourcing view buffer.")

(defvar-local decknix--agent-resourcing-source nil
  "Plist (:conv-key :session-id :provider) of the conversation shown here.
Captured from the originating agent-shell buffer so `g' can refresh
without needing to be run from that buffer.")

(defun decknix--agent-resourcing-hub-items ()
  "Return a flat list of hub PR alists (reviews + WIP) for URL matching.
Empty when the hub is disabled."
  (append
   (copy-sequence (alist-get 'items (bound-and-true-p decknix--hub-reviews)))
   (mapcan (lambda (repo-entry)
             (copy-sequence (alist-get 'prs repo-entry)))
           (alist-get 'repos (bound-and-true-p decknix--hub-wip)))))

(defun decknix--agent-resourcing-collect (source)
  "Build the resource tree for SOURCE (:conv-key :session-id :provider).
Reads the live link store, sub-agent walk and hub globals; the shaping
and attention rollup are done by the pure `decknix-agent-resourcing'
layer."
  (let* ((conv-key (plist-get source :conv-key))
         (session-id (plist-get source :session-id))
         (provider (plist-get source :provider))
         (now (float-time))
         (linked-prs (and conv-key (decknix--agent-linked-prs conv-key)))
         (linked-repos (and conv-key (decknix--agent-linked-repos conv-key)))
         (subagents (and session-id
                         (fboundp 'decknix--agent-session-subagents)
                         (decknix--agent-session-subagents session-id provider)))
         (hub-items (decknix--agent-resourcing-hub-items)))
    (decknix--agent-resource-tree
     (list (decknix--agent-resource-subagents subagents now t)
           (decknix--agent-resource-prs linked-prs hub-items)
           (decknix--agent-resource-repos linked-repos)))))

(defun decknix--agent-resourcing-attention-face (attention)
  "Map an ATTENTION symbol to a display face."
  (pcase attention
    ('red 'error)
    ('amber 'warning)
    ('green 'success)
    (_ 'shadow)))

(defun decknix--agent-resourcing-open-at-point ()
  "Open the URL of the resource row at point, or describe a sub-agent."
  (interactive)
  (let ((url (get-text-property (line-beginning-position)
                                'decknix-resourcing-url))
        (item (get-text-property (line-beginning-position)
                                 'decknix-resourcing-item)))
    (cond
     ((and url (not (string-empty-p url))) (browse-url url))
     (item (message "%s" (plist-get item :label)))
     (t (message "No resource on this line")))))

(defun decknix--agent-resourcing-insert-item (item)
  "Insert one resource ITEM row, propertised with its URL + plist."
  (let* ((face (decknix--agent-resourcing-attention-face
                (plist-get item :attention)))
         (state (plist-get item :state))
         (line (format "    %s %s"
                       (propertize "●" 'face face)
                       (plist-get item :label))))
    (insert (propertize line
                        'decknix-resourcing-url (plist-get item :url)
                        'decknix-resourcing-item item))
    (when state
      (insert (propertize (format "  [%s]" state) 'face 'shadow)))
    (insert "\n")))

(defun decknix-agent-resourcing-refresh (&optional source)
  "Rebuild the resourcing buffer.  With SOURCE, (re)bind the conversation."
  (interactive)
  (let ((buf (get-buffer-create decknix-agent-resourcing-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-agent-resourcing-mode)
        (decknix-agent-resourcing-mode))
      (when source (setq decknix--agent-resourcing-source source))
      (let* ((tree (decknix--agent-resourcing-collect
                    decknix--agent-resourcing-source))
             (cats (plist-get tree :categories))
             (inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Resources — this conversation\n\n" 'face 'bold))
        (if (null cats)
            (insert (propertize "  (no resources linked to this conversation)\n"
                                'face 'shadow))
          (dolist (cat cats)
            (let ((items (plist-get cat :items)))
              (insert (propertize
                       (format "%s (%d)\n" (plist-get cat :label) (length items))
                       'face 'font-lock-keyword-face))
              (dolist (it items) (decknix--agent-resourcing-insert-item it))
              (insert "\n")))))
      (goto-char (point-min)))
    buf))

(defvar decknix-agent-resourcing-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix--agent-resourcing-open-at-point)
    (define-key map (kbd "g")   #'decknix-agent-resourcing-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `decknix-agent-resourcing-mode'.")

(define-derived-mode decknix-agent-resourcing-mode special-mode "Resources"
  "Major mode for the per-conversation resourcing view.")

(defun decknix-agent-resourcing ()
  "Open the resourcing view for the current conversation (`C-c s a').
Captures the conversation identity from the current agent-shell buffer,
then shows its sub-agents, linked PRs and linked repos in a standalone
`*Agent Resources*' buffer."
  (interactive)
  (let ((source
         (list :conv-key (and (fboundp 'decknix--agent-current-conv-key)
                              (decknix--agent-current-conv-key))
               :session-id (and (fboundp 'decknix--agent-buffer-session-id)
                                (decknix--agent-buffer-session-id))
               :provider (bound-and-true-p decknix--agent-provider-id))))
    (pop-to-buffer (decknix-agent-resourcing-refresh source))))

(provide 'decknix-agent-resourcing-ui)
;;; decknix-agent-resourcing-ui.el ends here
