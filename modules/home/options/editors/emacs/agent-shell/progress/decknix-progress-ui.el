;;; decknix-progress-ui.el --- Magit-style buffer view for decknix-progress -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-progress "0.1"))
;; Keywords: agent, progress, tools

;;; Commentary:
;;
;; Magit-style hierarchical view over the data layer in `decknix-progress'.
;; Each conversation key gets its own buffer keyed by
;; `decknix-progress--conv-key'; sections are grouped by provider symbol via
;; `decknix-progress-provider-labels' (extensible — add (linear . "Linear")
;; to wire a new task system in without touching this code).
;;
;; The buffer is a thin renderer over `decknix-progress-for-conv-key':
;; full re-render on every refresh keeps state management trivial
;; (typical payload <200 items; render is microseconds).  Fold state
;; persists across refreshes via a buffer-local hash keyed by item id.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'decknix-progress)

;; -- Forward declarations: functions defined elsewhere in agent-shell config --
(declare-function decknix--agent-current-conv-key "ext:agent-shell-config")
(declare-function decknix--agent-tags-read "ext:agent-shell-config")
(declare-function decknix--agent-tags-conversations "ext:agent-shell-config" (store))
(declare-function decknix--open-url "ext:agent-shell-config" (url &optional new-session))
(defvar decknix-agent-prefix-map)

;; == Progress UI: dedicated `*decknix-progress*' buffer (PR 2) ==
;;
;; Magit-style hierarchical view over the data layer above.  Each
;; conversation key gets its own buffer keyed by `decknix-progress--conv-key';
;; sections are grouped by provider symbol via
;; `decknix-progress-provider-labels' (extensible — add (linear . "Linear")
;; to wire a new task system in without touching this code).
;;
;; The buffer is a thin renderer over `decknix-progress-for-conv-key':
;; full re-render on every refresh keeps state management trivial
;; (typical payload <200 items; render is microseconds).  Fold state
;; persists across refreshes via a buffer-local hash keyed by item id.

;; -- Faces --

(defface decknix-progress-attention-red
  '((t :foreground "#e06c75" :weight bold))
  "Face for items needing immediate action."
  :group 'decknix)

(defface decknix-progress-attention-amber
  '((t :foreground "#e5c07b"))
  "Face for items waiting on something."
  :group 'decknix)

(defface decknix-progress-attention-green
  '((t :foreground "#98c379"))
  "Face for items in good shape."
  :group 'decknix)

(defface decknix-progress-attention-none
  '((t :inherit shadow))
  "Face for items with no signal."
  :group 'decknix)

(defface decknix-progress-state-done
  '((t :inherit shadow :strike-through t))
  "Face applied to titles of done items."
  :group 'decknix)

(defface decknix-progress-state-blocked
  '((t :foreground "#e06c75"))
  "Face applied to titles of blocked items."
  :group 'decknix)

(defface decknix-progress-section-heading
  '((t :inherit bold))
  "Face for provider section headings in the progress buffer."
  :group 'decknix)

;; -- Customs --

(defcustom decknix-progress-provider-labels
  '((todo . "TODO Stream")
    (jira . "Tasks")
    (pr   . "Pull Requests"))
  "Display label for each progress `:provider' symbol.
Add an entry here when wiring a new provider via
`decknix-progress-adapter-functions' — e.g. `(linear . \"Linear\")'.
Unknown providers fall back to the symbol name."
  :type '(alist :key-type symbol :value-type string)
  :group 'decknix)

(defcustom decknix-progress-buffer-name "*decknix-progress*"
  "Name of the dedicated progress buffer."
  :type 'string
  :group 'decknix)

(defcustom decknix-progress-collapse-done t
  "When non-nil, items in the `done' state start collapsed.
Children of done items are still expandable via TAB."
  :type 'boolean
  :group 'decknix)

;; -- Buffer-local state --

(defvar-local decknix-progress--conv-key nil
  "Conversation key this `*decknix-progress*' buffer is showing.")

(defvar-local decknix-progress--payload nil
  "Last payload rendered (from `decknix-progress-for-conv-key').")

(defvar-local decknix-progress--fold-state nil
  "Hash table mapping item-id (string) → t when collapsed.")

(defvar-local decknix-progress--watch nil
  "File-notify descriptor for this buffer's snapshot, if any.")

;; -- Glyph / face helpers --

(defun decknix-progress--state-glyph (state)
  "Return a single-char glyph for STATE."
  (pcase state
    ('todo    "☐")
    ('wip     "◐")
    ('blocked "⊘")
    ('done    "☒")
    (_        "·")))

(defun decknix-progress--attention-glyph (att)
  "Return an attention dot for ATT (red/amber/green/none)."
  (pcase att
    ('red   "●")
    ('amber "●")
    ('green "●")
    (_      "·")))

(defun decknix-progress--attention-face (att)
  "Return the face symbol for attention ATT."
  (pcase att
    ('red   'decknix-progress-attention-red)
    ('amber 'decknix-progress-attention-amber)
    ('green 'decknix-progress-attention-green)
    (_      'decknix-progress-attention-none)))

(defun decknix-progress--title-face (state)
  "Return an extra face to overlay on the title for STATE, or nil."
  (pcase state
    ('done    'decknix-progress-state-done)
    ('blocked 'decknix-progress-state-blocked)
    (_        nil)))

(defun decknix-progress--provider-label (provider)
  "Return the display label for PROVIDER symbol."
  (or (alist-get provider decknix-progress-provider-labels)
      (symbol-name (or provider 'unknown))))

;; -- Mode + keymap --

(defvar decknix-progress-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "TAB")     'decknix-progress-toggle)
    (define-key m (kbd "<tab>")   'decknix-progress-toggle)
    (define-key m (kbd "RET")     'decknix-progress-open-at-point)
    (define-key m (kbd "M-RET")   'decknix-progress-open-at-point)
    (define-key m (kbd "g")       'decknix-progress-refresh)
    (define-key m (kbd "n")       'decknix-progress-next-item)
    (define-key m (kbd "p")       'decknix-progress-previous-item)
    (define-key m (kbd "q")       'quit-window)
    m)
  "Keymap for `decknix-progress-mode'.")

(define-derived-mode decknix-progress-mode special-mode "Progress"
  "Major mode for the dedicated progress buffer.
Shows a per-conversation aggregate of TODO-stream items, hub PRs,
and tasks from the configured task system(s) in a Magit-style
hierarchical view."
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box)
  (setq-local decknix-progress--fold-state
              (make-hash-table :test 'equal))
  (buffer-disable-undo))

;; -- Render --

(defun decknix-progress--group-by-provider (items)
  "Return ITEMS grouped by `:provider', preserving first-seen order.
Result is a list of (PROVIDER . ITEMS-IN-ORDER)."
  (let ((order nil)
        (groups (make-hash-table :test 'eq)))
    (dolist (it items)
      (let ((p (or (plist-get it :provider) 'unknown)))
        (unless (gethash p groups)
          (push p order))
        (puthash p (cons it (gethash p groups)) groups)))
    (mapcar (lambda (p) (cons p (nreverse (gethash p groups))))
            (nreverse order))))

(defun decknix-progress--count-summary (items)
  "Return a (DONE . TOTAL) summary for ITEMS (recursive)."
  (let ((done 0) (total 0))
    (cl-labels ((walk (xs)
                  (dolist (it xs)
                    (cl-incf total)
                    (when (eq (plist-get it :state) 'done)
                      (cl-incf done))
                    (walk (plist-get it :children)))))
      (walk items))
    (cons done total)))

(defun decknix-progress--folded-p (item-id default)
  "Return non-nil when ITEM-ID is folded in the current buffer.
DEFAULT is returned when no explicit state has been set."
  (if (and decknix-progress--fold-state
           (not (eq (gethash item-id decknix-progress--fold-state 'unset)
                    'unset)))
      (gethash item-id decknix-progress--fold-state)
    default))

(defun decknix-progress--insert-header (payload)
  "Insert the header lines for PAYLOAD into the current buffer."
  (let* ((conv-key (plist-get payload :conv-key))
         (att      (or (plist-get payload :attention) 'none))
         (items    (plist-get payload :items))
         (sum      (decknix-progress--count-summary items))
         (done     (car sum))
         (total    (cdr sum))
         (tags     (when (fboundp 'decknix--agent-tags-for-conv-key)
                     (decknix--agent-tags-for-conv-key conv-key)))
         (short    (if (and conv-key (>= (length conv-key) 8))
                       (substring conv-key 0 8)
                     (or conv-key "?"))))
    (insert (propertize "Progress  " 'face 'bold))
    (insert (propertize
             (decknix-progress--attention-glyph att)
             'face (decknix-progress--attention-face att)))
    (insert (format "  %s" (propertize short 'face
                                        'font-lock-constant-face)))
    (when tags
      (insert (propertize (format "  [%s]" (string-join tags ","))
                          'face 'font-lock-comment-face)))
    (insert (format "  %d/%d done\n"
                    done total))
    (insert (propertize
             "  TAB fold · RET/M-RET open · g refresh · n/p move · q quit\n"
             'face 'font-lock-comment-face))
    (insert "\n")))

(defun decknix-progress--insert-item (item depth)
  "Insert ITEM at indentation DEPTH; recurse into children unless folded."
  (let* ((id        (or (plist-get item :id) ""))
         (state     (or (plist-get item :state) 'todo))
         (att       (or (plist-get item :attention) 'none))
         (rolled    (decknix-progress--rollup-attention item))
         (title     (or (plist-get item :title) ""))
         (url       (plist-get item :url))
         (children  (plist-get item :children))
         (default-fold (and decknix-progress-collapse-done
                            (eq state 'done)
                            children))
         (folded    (and children
                         (decknix-progress--folded-p id default-fold)))
         (indent    (make-string (* depth 2) ?\s))
         (caret     (cond ((null children) " ")
                          (folded "▶")
                          (t      "▼")))
         (state-g   (decknix-progress--state-glyph state))
         (att-g     (decknix-progress--attention-glyph rolled))
         (att-face  (decknix-progress--attention-face rolled))
         (title-face (decknix-progress--title-face state))
         (start (point)))
    (insert indent)
    (insert (propertize caret 'face 'font-lock-comment-face))
    (insert " ")
    (insert (propertize state-g 'face att-face))
    (insert " ")
    (insert (propertize att-g 'face att-face))
    (insert " ")
    (let ((title-start (point)))
      (insert title)
      (when title-face
        (add-face-text-property title-start (point) title-face)))
    (insert "\n")
    (add-text-properties
     start (point)
     (list 'decknix-progress-item-id id
           'decknix-progress-item-url url
           'decknix-progress-has-children (and children t)))
    (when (and children (not folded))
      (dolist (c children)
        (decknix-progress--insert-item c (1+ depth))))))

(defun decknix-progress--insert-section (provider items)
  "Insert a section heading for PROVIDER and its ITEMS."
  (let* ((sum   (decknix-progress--count-summary items))
         (done  (car sum))
         (total (cdr sum))
         (sec-id (format "__section__:%s" provider))
         (folded (decknix-progress--folded-p sec-id nil))
         (caret  (if folded "▶" "▼"))
         (label  (decknix-progress--provider-label provider))
         (start  (point)))
    (insert (propertize caret 'face 'font-lock-comment-face))
    (insert " ")
    (insert (propertize (format "%s" label)
                        'face 'decknix-progress-section-heading))
    (insert (propertize (format "  (%d/%d)\n" done total)
                        'face 'font-lock-comment-face))
    (add-text-properties
     start (point)
     (list 'decknix-progress-item-id sec-id
           'decknix-progress-section provider
           'decknix-progress-has-children t))
    (unless folded
      (dolist (it items)
        (decknix-progress--insert-item it 1)))
    (insert "\n")))

(defun decknix-progress--render (payload)
  "Render PAYLOAD into the current buffer, replacing existing content."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (col  (current-column)))
    (erase-buffer)
    (decknix-progress--insert-header payload)
    (let ((items (plist-get payload :items)))
      (if (null items)
          (insert (propertize "  (no items)\n" 'face 'shadow))
        (dolist (group (decknix-progress--group-by-provider items))
          (decknix-progress--insert-section (car group) (cdr group)))))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column col)))

;; -- Interaction --

(defun decknix-progress--item-at-point ()
  "Return the item-id text-property at point, or nil."
  (get-text-property (line-beginning-position)
                     'decknix-progress-item-id))

(defun decknix-progress--url-at-point ()
  "Return the url text-property at point, or nil."
  (get-text-property (line-beginning-position)
                     'decknix-progress-item-url))

(defun decknix-progress-toggle ()
  "Toggle the fold state of the item at point."
  (interactive)
  (let ((id (decknix-progress--item-at-point))
        (has-children (get-text-property (line-beginning-position)
                                         'decknix-progress-has-children)))
    (cond
     ((not id)
      (user-error "No item on this line"))
     ((not has-children)
      (message "No children to fold"))
     (t
      (let ((cur (decknix-progress--folded-p id nil)))
        (puthash id (not cur) decknix-progress--fold-state))
      (when decknix-progress--payload
        (decknix-progress--render decknix-progress--payload))))))

(defun decknix-progress-open-at-point ()
  "Open the URL for the item at point in the configured browser.
Falls back to copying the item id if the row carries no URL."
  (interactive)
  (let ((url (decknix-progress--url-at-point))
        (id  (decknix-progress--item-at-point)))
    (cond
     ((and url (not (string-empty-p url)))
      (cond
       ((fboundp 'decknix--open-url) (decknix--open-url url))
       (t (browse-url url))))
     (id
      (kill-new id)
      (message "No URL on this row — copied id: %s" id))
     (t (user-error "No actionable item on this line")))))

(defun decknix-progress-next-item ()
  "Move to the next item line."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (decknix-progress--item-at-point)))
      (forward-line 1))
    (when (eobp)
      (goto-char start)
      (message "No next item"))))

(defun decknix-progress-previous-item ()
  "Move to the previous item line."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (decknix-progress--item-at-point)))
      (forward-line -1))
    (when (bobp)
      (goto-char start)
      (message "No previous item"))))

(defun decknix-progress-refresh ()
  "Recompute and re-render the progress for the current buffer's conv-key.
Also persists the snapshot so the global index stays warm for future
sidebar integration."
  (interactive)
  (unless decknix-progress--conv-key
    (user-error "No conv-key bound to this buffer"))
  (let ((payload (decknix-progress-refresh-conv-key
                  decknix-progress--conv-key)))
    (setq-local decknix-progress--payload payload)
    (decknix-progress--render payload)
    (message "Progress refreshed")))

;; -- File-notify: re-render when the snapshot changes externally --

(defun decknix-progress--watch-callback (event)
  "Handle file-notify EVENT by re-rendering if the buffer is still live."
  (let* ((action (nth 1 event))
         (path   (nth 2 event)))
    (when (memq action '(changed created attribute-changed))
      (let* ((buf-name decknix-progress-buffer-name)
             (buf (get-buffer buf-name)))
        (when (and buf (buffer-live-p buf)
                   (with-current-buffer buf
                     (and decknix-progress--conv-key
                          (string= path
                                   (decknix-progress--snapshot-path
                                    decknix-progress--conv-key)))))
          (with-current-buffer buf
            (let ((payload (condition-case _err
                               (decknix-progress-for-conv-key
                                decknix-progress--conv-key)
                             (error nil))))
              (when payload
                (setq-local decknix-progress--payload payload)
                (decknix-progress--render payload)))))))))

(defun decknix-progress--start-watch (conv-key)
  "Watch the snapshot file for CONV-KEY; re-render on change."
  (decknix-progress--ensure-dir)
  (let ((path (decknix-progress--snapshot-path conv-key)))
    (when (and (boundp 'decknix-progress--watch)
               decknix-progress--watch)
      (ignore-errors (file-notify-rm-watch decknix-progress--watch)))
    (setq-local decknix-progress--watch
                (condition-case _err
                    (file-notify-add-watch
                     path '(change attribute-change)
                     #'decknix-progress--watch-callback)
                  (error nil)))))

;; -- Conv-key picker (uses index.json + agent-tags) --

(defun decknix-progress--known-conv-keys ()
  "Return a list of known conv-keys, deduped, with display labels.
Sources: the agent-tags store (so freshly-named conversations show up
even before their first snapshot) plus the global index (so hub-only
conv-keys still show up).  Result is a list of (LABEL . CONV-KEY)."
  (let ((seen (make-hash-table :test 'equal))
        (entries nil))
    (cl-flet ((add (ck)
                (when (and ck (not (gethash ck seen)))
                  (puthash ck t seen)
                  (let* ((tags (when (fboundp
                                      'decknix--agent-tags-for-conv-key)
                                 (decknix--agent-tags-for-conv-key ck)))
                         (short (if (>= (length ck) 8)
                                    (substring ck 0 8) ck))
                         (label (if tags
                                    (format "%s  [%s]" short
                                            (string-join tags ","))
                                  short)))
                    (push (cons label ck) entries)))))
      (when (fboundp 'decknix--agent-tags-read)
        (let* ((store (decknix--agent-tags-read))
               (convs (decknix--agent-tags-conversations store)))
          (when (hash-table-p convs)
            (maphash (lambda (k _v) (add k)) convs))))
      (let ((idx (decknix-progress--read-index)))
        (when (hash-table-p idx)
          (maphash (lambda (k _v) (add k)) idx))))
    (nreverse entries)))

(defun decknix-progress--pick-conv-key ()
  "Prompt for a conv-key via completing-read; return the key string."
  (let* ((entries (decknix-progress--known-conv-keys))
         (_ (when (null entries)
              (user-error "No known conversations yet")))
         (choice (completing-read "Conversation: "
                                  (mapcar #'car entries)
                                  nil t)))
    (cdr (assoc choice entries))))

;; -- Entry points --

(defun decknix-progress (&optional conv-key)
  "Open `*decknix-progress*' for CONV-KEY (interactively prompts).
With no current agent-shell session, prompts via
`decknix-progress--pick-conv-key'."
  (interactive
   (list (or (when (fboundp 'decknix--agent-current-conv-key)
               (decknix--agent-current-conv-key))
             (decknix-progress--pick-conv-key))))
  (unless (and conv-key (not (string-empty-p conv-key)))
    (user-error "No conv-key supplied"))
  (let* ((buf (get-buffer-create decknix-progress-buffer-name)))
    (with-current-buffer buf
      (decknix-progress-mode)
      (setq-local decknix-progress--conv-key conv-key)
      (let ((payload (decknix-progress-refresh-conv-key conv-key)))
        (setq-local decknix-progress--payload payload)
        (decknix-progress--render payload))
      (decknix-progress--start-watch conv-key))
    (pop-to-buffer buf)))

(defun decknix-progress-current ()
  "Open `*decknix-progress*' for the current agent-shell buffer's conv-key."
  (interactive)
  (let ((ck (when (fboundp 'decknix--agent-current-conv-key)
              (decknix--agent-current-conv-key))))
    (unless ck
      (user-error "Not in an agent-shell session — use `M-x decknix-progress'"))
    (decknix-progress ck)))

;; -- Key binding --
;;
;; The `C-c A P' binding lives in the surrounding `default.el' (right after
;; the `(require ...)' calls) so that this file does not depend on the
;; surrounding heredoc having already evaluated `decknix-agent-prefix-map'
;; by the time the byte-compiler triggers `(require ...)' for it.

(provide 'decknix-progress-ui)
;;; decknix-progress-ui.el ends here
