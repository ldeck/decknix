;;; decknix-layout-groups.el --- Named window-layout groups (#169) -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, windows, layout

;;; Commentary:
;;
;; Named window-layout groups (#169): winner-mode-style switching between
;; saved tiled window arrangements — NOT tab-bar tabs (which collide with
;; the one-tab-per-agent `agent-shell-workspace' model).  Each group is a
;; serialized `window-state', so groups persist across `decknix switch'
;; and restore whatever of their buffers still exist.
;;
;; Compose with the #168 tiling primitive
;; (`decknix--agent-tile-buffers-as-splits') to build a group's layout
;; from marked sessions, then `decknix-layout-group-save' to name it.
;;
;; The switcher sorts groups whose agent-shells NEED ATTENTION to the top,
;; so switching goes to the most-actionable work-stream first.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function decknix-agent-buffer-status "decknix-agent-auto-close" (buffer))
(declare-function agent-shell-buffers "ext:agent-shell")

(defgroup decknix-layout-groups nil
  "Named window-layout groups."
  :group 'decknix)

(defcustom decknix-layout-groups-file
  (expand-file-name "decknix/layout-groups.el" user-emacs-directory)
  "File where named layout groups are persisted."
  :type 'file :group 'decknix-layout-groups)

(defcustom decknix-layout-group-attention-statuses '(needs-attention error blocked)
  "Buffer statuses (from `decknix-agent-buffer-status') that mark a group
as needing attention, so it sorts to the top of the switcher."
  :type '(repeat symbol) :group 'decknix-layout-groups)

(defvar decknix-layout-groups nil
  "Alist of (NAME . WINDOW-STATE) for saved tiled window layouts.
WINDOW-STATE is a `window-state-get' snapshot (serializable).")

;; -- Persistence --------------------------------------------------------

(defun decknix-layout-groups--persist ()
  "Write `decknix-layout-groups' to `decknix-layout-groups-file'."
  (ignore-errors
    (let ((dir (file-name-directory decknix-layout-groups-file)))
      (unless (file-directory-p dir) (make-directory dir t)))
    (with-temp-file decknix-layout-groups-file
      (let ((print-level nil) (print-length nil))
        (prin1 decknix-layout-groups (current-buffer))))))

;;;###autoload
(defun decknix-layout-groups-restore ()
  "Load saved layout groups from disk into `decknix-layout-groups'."
  (when (file-readable-p decknix-layout-groups-file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents decknix-layout-groups-file)
        (setq decknix-layout-groups (read (current-buffer)))))))

;; -- Attention model ----------------------------------------------------

(defun decknix-layout-group--state-buffers (state)
  "Return the list of live buffers referenced by window-STATE."
  (let (bufs)
    (cl-labels ((walk (node)
                  (when (consp node)
                    (if (eq (car node) 'leaf)
                        (let* ((params (cdr node))
                               (bufentry (alist-get 'buffer params))
                               (name (cond ((stringp bufentry) bufentry)
                                           ((consp bufentry) (car bufentry)))))
                          (when (and name (get-buffer name))
                            (push (get-buffer name) bufs)))
                      (dolist (child (cdr node)) (walk child))))))
      (walk state))
    (nreverse bufs)))

(defun decknix-layout-group--attention-p (name)
  "Return non-nil when layout group NAME holds an attention-needing agent."
  (let ((state (alist-get name decknix-layout-groups nil nil #'equal)))
    (and state
         (fboundp 'decknix-agent-buffer-status)
         (seq-some
          (lambda (b)
            (memq (ignore-errors (decknix-agent-buffer-status b))
                  decknix-layout-group-attention-statuses))
          (decknix-layout-group--state-buffers state)))))

(defun decknix-layout-group--names-sorted ()
  "Return group names, attention-needing ones first, then most-recent order."
  (let* ((names (mapcar #'car decknix-layout-groups))
         (attn (seq-filter #'decknix-layout-group--attention-p names))
         (rest (seq-remove #'decknix-layout-group--attention-p names)))
    (append attn rest)))

(defun decknix-layout-group--annotate (name)
  "Return an annotation string for group NAME (attention marker)."
  (if (decknix-layout-group--attention-p name) "  ● needs attention" ""))

(defun decknix-layout-group--read (prompt)
  "Read a saved group name with PROMPT, attention-sorted, annotated."
  (unless decknix-layout-groups (user-error "No saved layout groups"))
  (let* ((names (decknix-layout-group--names-sorted))
         (completion-extra-properties
          (list :annotation-function #'decknix-layout-group--annotate)))
    (completing-read prompt names nil t)))

;; -- Commands -----------------------------------------------------------

;;;###autoload
(defun decknix-layout-group-save (name)
  "Save the current frame's window layout as group NAME.
Overwrites an existing group of the same name."
  (interactive
   (list (completing-read "Save layout group as: "
                          (mapcar #'car decknix-layout-groups))))
  (when (string-empty-p name) (user-error "Empty group name"))
  (setf (alist-get name decknix-layout-groups nil nil #'equal)
        (window-state-get (frame-root-window) t))
  (decknix-layout-groups--persist)
  (message "Saved layout group %S" name))

;;;###autoload
(defun decknix-layout-group-switch (name)
  "Switch the current frame to saved layout group NAME.
Attention-needing groups are offered first."
  (interactive (list (decknix-layout-group--read "Switch to layout group: ")))
  (let ((state (alist-get name decknix-layout-groups nil nil #'equal)))
    (if (not state)
        (user-error "No layout group %S" name)
      (window-state-put state (frame-root-window) 'safe)
      (message "Layout group %S%s" name
               (if (decknix-layout-group--attention-p name) " (needs attention)" "")))))

;;;###autoload
(defun decknix-layout-group-delete (name)
  "Delete saved layout group NAME."
  (interactive (list (decknix-layout-group--read "Delete layout group: ")))
  (setq decknix-layout-groups
        (assoc-delete-all name decknix-layout-groups #'equal))
  (decknix-layout-groups--persist)
  (message "Deleted layout group %S" name))

;;;###autoload
(defun decknix-layout-group-save-from-tiled-sessions (name buffers)
  "Tile BUFFERS as splits (via #168) then save the layout as group NAME.
Convenience bridge from the session picker's marked set to a named group."
  (when (fboundp 'decknix--agent-tile-buffers-as-splits)
    (decknix--agent-tile-buffers-as-splits buffers))
  (decknix-layout-group-save name))

(provide 'decknix-layout-groups)
;;; decknix-layout-groups.el ends here
