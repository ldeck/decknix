;;; decknix-layout-persist.el --- Save and restore frames, tabs and windows across restarts -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: frames, windows, tab-bar, agent-shell, decknix

;;; Commentary:
;;
;; A `decknix switch' ends with the daemon restarted
;; (`launchctl kickstart -k' sends SIGTERM, which Emacs turns into
;; `kill-emacs' and so runs `kill-emacs-hook') and a fresh client frame.
;; Everything that was open -- frames, their tab-bar tabs, the window
;; splits in each tab, and the agent sessions shown in them -- had to be
;; rebuilt by hand.  This package records that layout and offers it back.
;;
;; Not `desktop-save-mode': desktop restores EVERY file buffer (and starts
;; their language servers) and replays frames as soon as it is read, which
;; in a daemon means before any frame exists.  Here only buffers that are
;; actually shown in a window are recorded, nothing is restored until a
;; GUI frame asks for it, and agent sessions are resumed through the same
;; path as the sidebar's Previous restore.
;;
;; The model is plain data (`read'-able, no buffer or window objects):
;;
;;   (:version 1 :saved-at FLOAT
;;    :buffers ((NAME . (:kind file   :file PATH))
;;              (NAME . (:kind dired  :dir PATH))
;;              (NAME . (:kind magit  :dir PATH))
;;              (NAME . (:kind command :fn SYMBOL))
;;              (NAME . (:kind agent  :session ENTRY))
;;              (NAME . (:kind sidebar))
;;              (NAME . (:kind other)))
;;    :frames ((:params ALIST :selected BOOL :current-tab N
;;              :tabs ((:name STR :explicit BOOL :state WINDOW-STATE) ...))))
;;
;; WINDOW-STATE is `window-state-get' in writable form, so buffers appear
;; by NAME; restore resolves each name to a live buffer first and rewrites
;; the state to whatever that buffer is now called.  ENTRY is the alist the
;; Previous-sessions list uses (session-id, name, workspace, conv-key,
;; tags), so a recorded session resumes exactly as `p' in the sidebar would.
;;
;; Side effects (hooks, the autosave timer) are installed only by
;; `decknix-layout-persist-enable', called from the heredoc.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(declare-function tab-bar-tabs "tab-bar" (&optional frame))
(declare-function tab-bar-new-tab "tab-bar" (&optional arg from-number))
(declare-function tab-bar-rename-tab "tab-bar" (name &optional tab-number))
(declare-function tab-bar-select-tab "tab-bar" (&optional tab-number))
(declare-function tab-bar-close-other-tabs "tab-bar" (&optional tab-number))
(declare-function dired-noselect "dired" (dir-or-list &optional switches))
(declare-function magit-status-setup-buffer "ext:magit-status" (&optional directory))
(declare-function agent-shell-buffers "ext:agent-shell")
(declare-function agent-shell-workspace-sidebar-open "ext:agent-shell-workspace")
(declare-function agent-shell-workspace--on-tab-selected "ext:agent-shell-workspace" (&rest args))
(declare-function decknix--agent-buffer-session-id "decknix-agent-buffer-lookup" (&optional buf))
(declare-function decknix--agent-find-live-buffer-for-conv-key "decknix-agent-buffer-lookup" (conv-key))
(declare-function decknix--agent-find-live-buffer-for-session-id "decknix-agent-buffer-lookup" (session-id))
(declare-function decknix--agent-tags-for-buffer "decknix-agent-tags-read" (buffer))
(declare-function decknix--agent-workspace-for-conv-key "decknix-agent-session-workspace" (conv-key))
(declare-function decknix--sidebar-restore-previous-session "decknix-agent-shell-workspace"
                  (entry &optional focus))
(declare-function decknix--agent-session-resume "decknix-agent-shell-main-session"
                  (session-id history-count &optional display-name workspace conv-key search-term))

(defvar decknix--agent-conv-key)
(defvar agent-shell-workspace--isolation-active)
(defvar decknix--sidebar-tile-auto-suspended)
(defvar decknix--agent-session-workspace)
(defvar dired-directory)
(defvar agent-shell-workspace-sidebar-buffer-name "*Agent Sidebar*")

(defgroup decknix-layout-persist nil
  "Save and restore frames, tabs and windows across Emacs restarts."
  :group 'decknix)

(defcustom decknix-layout-persist-file
  (expand-file-name "decknix/emacs-layout.el"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state" "~")))
  "File the frame/tab/window layout is saved to.
A STATE dir rather than `~/.config/decknix', which is configuration."
  :type 'file :group 'decknix-layout-persist)

(defcustom decknix-layout-restore-on-start 'ask
  "What to do with a saved layout when the first GUI frame of a daemon opens.
`ask'    prompt once (layout and sessions / layout only / no),
`notify' only say a layout is available and how to restore it,
t        restore without asking,
nil      do nothing (\\[decknix-layout-restore] still works)."
  :type '(choice (const :tag "Ask" ask) (const :tag "Notify only" notify)
                 (const :tag "Restore automatically" t) (const :tag "Off" nil))
  :group 'decknix-layout-persist)

(defcustom decknix-layout-restore-sessions t
  "Non-nil to resume recorded agent sessions as part of a restore.
When nil, each window that showed a session gets a placeholder that
resumes it on RET, so sessions start only when you look at them."
  :type 'boolean :group 'decknix-layout-persist)

(defcustom decknix-layout-restore-max-age (* 3 24 60 60)
  "Seconds after which a saved layout is too old to offer at startup."
  :type 'integer :group 'decknix-layout-persist)

(defcustom decknix-layout-autosave-interval 300
  "Seconds between periodic layout saves, or nil to save only on exit.
The periodic save is what survives a crash or SIGKILL, which skip
`kill-emacs-hook'.  It writes only when the layout changed."
  :type '(choice integer (const nil)) :group 'decknix-layout-persist)

(defcustom decknix-layout-recreate-alist
  '(("\\`\\*Review Board\\*\\'" . decknix-review-board)
    ("\\`\\*deckmacs: Session Board\\*\\'" . decknix-session-board)
    ("\\`\\*US Pilot Control\\*\\'" . nc-us-pilot-board)
    ("\\`\\*Messages\\*\\'" . messages-buffer))
  "How to rebuild buffers that visit no file, keyed by name or major mode.
Each entry is (KEY . FUNCTION).  KEY is a regexp matched against the
buffer name, or a major-mode symbol matched with `derived-mode-p'.
FUNCTION takes no arguments and makes the buffer; most are the command
that opens it.  Windows are put back around the call, so a command that
pops to its buffer does no harm, and its buffer is then found by the
saved name when it does not return it.

A buffer that matches is saved as (:kind command); anything else that
visits no file is saved as (:kind other) and only comes back if
something else recreated it first.  A FUNCTION that is not defined (a
package this machine does not load) is skipped.

Restore calls these synchronously, before the frames are rebuilt, so
each must return promptly: the defaults render from memory and start
any network reads as subprocesses (the US Pilot board's Jira reads are
`make-process').  A function that would block belongs behind a
placeholder instead."
  :type '(alist :key-type (choice (regexp :tag "Buffer name")
                                  (symbol :tag "Major mode"))
                :value-type function)
  :group 'decknix-layout-persist)

(defconst decknix-layout--version 1)

(defconst decknix-layout--frame-params '(left top width height fullscreen)
  "Frame parameters worth restoring.  All are numbers, symbols or
`(+ N)' position forms, so they print readably.")

;; -- Buffer references ----------------------------------------------------

(defun decknix-layout--agent-buffer-p (buffer)
  "Non-nil when BUFFER is an agent-shell session buffer."
  (with-current-buffer buffer (derived-mode-p 'agent-shell-mode)))

(defun decknix-layout--agent-entry (buffer)
  "Return the Previous-sessions style entry for agent BUFFER, or nil.
Same fields `decknix--sidebar-record-buffer-as-live' records, so the
restore can hand it straight to the sidebar's resume path."
  (with-current-buffer buffer
    (let* ((sid (and (fboundp 'decknix--agent-buffer-session-id)
                     (ignore-errors (decknix--agent-buffer-session-id buffer))))
           (ck (and (boundp 'decknix--agent-conv-key) decknix--agent-conv-key))
           (ws (or (and (boundp 'decknix--agent-session-workspace)
                        decknix--agent-session-workspace)
                   (and ck (fboundp 'decknix--agent-workspace-for-conv-key)
                        (ignore-errors (decknix--agent-workspace-for-conv-key ck)))
                   (expand-file-name default-directory)))
           (tags (and (fboundp 'decknix--agent-tags-for-buffer)
                      (ignore-errors (decknix--agent-tags-for-buffer buffer)))))
      (when (or sid ck)
        (list (cons 'session-id sid)
              (cons 'name (substring-no-properties (buffer-name buffer)))
              (cons 'workspace ws)
              (cons 'conv-key ck)
              (cons 'tags (mapcar #'substring-no-properties tags)))))))

(defun decknix-layout--buffer-ref (buffer)
  "Return a plain-data reference that can recreate BUFFER, or (:kind other)."
  (with-current-buffer buffer
    (cond
     ((equal (buffer-name buffer) agent-shell-workspace-sidebar-buffer-name)
      (list :kind 'sidebar))
     ((decknix-layout--agent-buffer-p buffer)
      (let ((entry (decknix-layout--agent-entry buffer)))
        (if entry (list :kind 'agent :session entry) (list :kind 'other))))
     (buffer-file-name
      (list :kind 'file :file (expand-file-name buffer-file-name)))
     ((and (derived-mode-p 'dired-mode) (stringp dired-directory))
      (list :kind 'dired :dir (expand-file-name dired-directory)))
     ((and (string-prefix-p "magit-" (symbol-name major-mode))
           (derived-mode-p 'magit-mode))
      (list :kind 'magit :dir (expand-file-name default-directory)))
     ((decknix-layout--recreate-fn (buffer-name buffer) major-mode)
      (list :kind 'command
            :fn (decknix-layout--recreate-fn (buffer-name buffer) major-mode)))
     (t (list :kind 'other)))))

;; -- Recreatable buffers ---------------------------------------------------

(defun decknix-layout--recreate-fn (name &optional mode)
  "The `decknix-layout-recreate-alist' function for buffer NAME in MODE, or nil."
  (cdr (seq-find (lambda (entry)
                   (let ((key (car entry)))
                     (if (stringp key)
                         (string-match-p key name)
                       (and mode (provided-mode-derived-p mode key)))))
                 decknix-layout-recreate-alist)))

(defun decknix-layout--recreate (name fn)
  "Call FN to rebuild the buffer saved as NAME; return it or nil.
`save-window-excursion' because the board commands `pop-to-buffer':
during a restore that would rearrange whichever frame happens to be
selected, which is not where the buffer is going."
  (when (fboundp fn)
    (let ((made (save-window-excursion (funcall fn))))
      (if (and (bufferp made) (buffer-live-p made)
               (equal (buffer-name made) name))
          made
        (get-buffer name)))))

;; -- Window-state walking -------------------------------------------------
;;
;; A window state mixes child NODES with parameter pairs in the same cdr:
;;   (hc (min-height . 8) (leaf ...) (leaf ...))
;; so only `leaf'/`hc'/`vc' conses are recursed into (the bug
;; `decknix-layout-group--state-buffers' documents).

(defun decknix-layout--node-p (x)
  (and (consp x) (memq (car x) '(leaf hc vc))))

(defun decknix-layout--state-buffer-names (state)
  "Return the buffer names shown by the leaves of window STATE.  Pure."
  (let (names)
    (cl-labels ((walk (node)
                  (if (eq (car-safe node) 'leaf)
                      (let ((b (alist-get 'buffer (cdr node))))
                        (when (stringp (car-safe b)) (push (car b) names)))
                    (dolist (child (cdr-safe node))
                      (when (decknix-layout--node-p child) (walk child))))))
      (when (consp state)
        ;; A full state is (PARAMS . ROOT-NODE); a bare node also works.
        (walk (if (decknix-layout--node-p state) state (cdr state)))))
    (delete-dups (nreverse names))))

(defun decknix-layout--state-rename-buffers (state mapping fallback)
  "Return a copy of window STATE with buffer names replaced.  Pure.
MAPPING is an alist of OLD-NAME -> NEW-NAME; a leaf whose name is not
in it shows FALLBACK instead, so the window survives rather than being
deleted by `window-state-put'.  Per-window prev/next buffer lists are
dropped: they name buffers that may not exist, and the tab's layout
history does not survive a restart anyway."
  (cl-labels ((leaf (params)
                (delq nil
                      (mapcar
                       (lambda (p)
                         (pcase (car-safe p)
                           ((or 'prev-buffers 'next-buffers) nil)
                           ('buffer
                            (let ((new (or (cdr (assoc (cadr p) mapping)) fallback)))
                              (cons 'buffer (cons new (copy-tree (cddr p))))))
                           (_ (copy-tree p))))
                       params)))
              (node (n)
                (if (eq (car n) 'leaf)
                    (cons 'leaf (leaf (cdr n)))
                  (cons (car n)
                        (mapcar (lambda (c)
                                  (if (decknix-layout--node-p c) (node c) (copy-tree c)))
                                (cdr n))))))
    (cond ((decknix-layout--node-p state) (node state))
          ((consp state) (cons (copy-tree (car state)) (node (cdr state))))
          (t state))))

;; Keys `window-state-get' records in pixels.  `window-state-put' decides
;; whether a state fits from these when present, so a state saved on a big
;; GUI frame is refused by a smaller one (another monitor, a terminal).
(defconst decknix-layout--pixel-keys
  '(pixel-width pixel-height min-pixel-height min-pixel-width
    min-pixel-height-ignore min-pixel-width-ignore
    min-pixel-height-safe min-pixel-width-safe))

(defun decknix-layout--state-without-pixels (state)
  "Return a copy of window STATE with its pixel sizes removed.  Pure.
`window-state-put' then checks and splits by lines and columns, using
the saved proportions, so the tab keeps its windows instead of failing."
  (cl-labels ((strip (params)
                (seq-remove (lambda (p) (memq (car-safe p) decknix-layout--pixel-keys))
                            params))
              (node (n)
                (cons (car n)
                      (mapcar (lambda (c) (if (decknix-layout--node-p c) (node c) c))
                              (strip (cdr n))))))
    (cond ((decknix-layout--node-p state) (node state))
          ((consp state) (cons (strip (car state)) (node (cdr state))))
          (t state))))

;; -- Capture ----------------------------------------------------------------

(defun decknix-layout--gui-frames ()
  "Live, visible, top-level GUI frames, selected frame first.
Child frames (completion popups) and the daemon's terminal frame are
not part of a layout."
  (let ((frames (seq-filter
                 (lambda (f)
                   (and (frame-live-p f)
                        (display-graphic-p f)
                        (frame-visible-p f)
                        (not (frame-parameter f 'parent-frame))
                        (not (eq (frame-parameter f 'minibuffer) 'only))))
                 (frame-list))))
    (if (memq (selected-frame) frames)
        (cons (selected-frame) (delq (selected-frame) frames))
      frames)))

(defun decknix-layout--tab-state (frame tab accurate)
  "Return the writable window state of TAB in FRAME.
The current tab is read live.  A background tab carries the state
tab-bar captured when it was left (`ws'), whose buffer names are stale
if a buffer was renamed since -- agent buffers rename themselves when
their tags change.  With ACCURATE, the tab's window configuration is
applied inside `save-window-excursion' to read today's names instead;
only on exit and on an explicit save, since it briefly swaps the
selected frame's windows."
  (if (eq (car tab) 'current-tab)
      (window-state-get (frame-root-window frame) t)
    (or (and accurate
             (window-configuration-p (alist-get 'wc tab))
             (ignore-errors
               (with-selected-frame frame
                 (save-current-buffer
                   (save-window-excursion
                     (set-window-configuration (alist-get 'wc tab) t)
                     (window-state-get (frame-root-window frame) t))))))
        (alist-get 'ws tab))))

(defun decknix-layout--capture (&optional accurate)
  "Return the current layout as plain data, or nil with no GUI frames.
ACCURATE is passed to `decknix-layout--tab-state'."
  (let ((frames (decknix-layout--gui-frames))
        (buffers nil))
    (when frames
      (let ((frame-models
             (mapcar
              (lambda (frame)
                (let* ((tabs (or (and (fboundp 'tab-bar-tabs) (tab-bar-tabs frame))
                                 (list (list 'current-tab))))
                       (current (or (seq-position tabs 'current-tab
                                                  (lambda (tab sym) (eq (car tab) sym)))
                                    0))
                       (tab-models
                        (mapcar
                         (lambda (tab)
                           (let ((state (decknix-layout--tab-state frame tab accurate)))
                             (dolist (name (decknix-layout--state-buffer-names state))
                               (unless (assoc name buffers)
                                 (let ((buf (get-buffer name)))
                                   (push (cons name (if buf
                                                        (decknix-layout--buffer-ref buf)
                                                      (list :kind 'missing)))
                                         buffers))))
                             (list :name (and (alist-get 'name tab)
                                              (substring-no-properties
                                               (alist-get 'name tab)))
                                   :explicit (and (alist-get 'explicit-name tab) t)
                                   :state state)))
                         tabs)))
                  (list :params (mapcar (lambda (p) (cons p (frame-parameter frame p)))
                                        decknix-layout--frame-params)
                        :selected (eq frame (selected-frame))
                        :current-tab current
                        :tabs tab-models)))
              frames)))
        (list :version decknix-layout--version
              :saved-at (float-time)
              :buffers (nreverse buffers)
              :frames frame-models)))))

;; -- Serialise ------------------------------------------------------------

(defun decknix-layout--print (layout)
  "Return LAYOUT printed readably, or nil when it holds an unreadable object.
A `#<' in the output means a buffer, marker or window slipped into the
model; writing that would make the file unreadable and lose the layout."
  (let ((text (with-output-to-string
                (let ((print-length nil) (print-level nil)
                      (print-circle nil) (print-escape-newlines t))
                  (prin1 layout)))))
    (unless (string-search "#<" text) text)))

(defun decknix-layout--parse (text)
  "Read a layout from TEXT; nil unless it is a layout of this version."
  (let ((data (ignore-errors (car (read-from-string text)))))
    (and (plistp data)
         (eql (plist-get data :version) decknix-layout--version)
         (plist-get data :frames)
         data)))

(defun decknix-layout--read-file (&optional file)
  (let ((file (or file decknix-layout-persist-file)))
    (when (file-readable-p file)
      (decknix-layout--parse
       (with-temp-buffer (insert-file-contents file) (buffer-string))))))

(defvar decknix-layout--last-written nil
  "Text of the last layout written, so an unchanged layout is not rewritten.")

(defvar decknix-layout--rotated nil
  "Non-nil once this run has kept the previous run's layout aside.")

(defun decknix-layout--comparable (layout)
  "LAYOUT without its timestamp, for change detection."
  (let ((copy (copy-sequence layout)))
    (plist-put copy :saved-at 0)))

(defun decknix-layout--write (layout)
  "Write LAYOUT atomically.  Returns non-nil when the file was written.
The first write of a run first copies the previous run's file to
`<file>.prev', so starting Emacs and quitting before restoring does not
destroy the layout worth restoring (\\[universal-argument] \\[decknix-layout-restore])."
  (let ((text (decknix-layout--print layout))
        (same (decknix-layout--print (decknix-layout--comparable layout))))
    (when (and text (not (equal same decknix-layout--last-written)))
      (let* ((file decknix-layout-persist-file)
             (dir (file-name-directory file)))
        (make-directory dir t)
        (unless decknix-layout--rotated
          (setq decknix-layout--rotated t)
          (when (file-exists-p file)
            (copy-file file (concat file ".prev") t)))
        (let ((tmp (make-temp-file (concat file ".tmp-"))))
          (with-temp-file tmp (insert text "\n"))
          (rename-file tmp file t))
        (setq decknix-layout--last-written same)
        t))))

;;;###autoload
(defun decknix-layout-save (&optional quiet accurate)
  "Save the frames, tabs and windows so they can be restored after a restart.
QUIET suppresses the message; ACCURATE (always for the command) reads
background tabs' current buffer names.  Never signals: a failing save
must not stop Emacs from quitting."
  (interactive (list nil t))
  (condition-case err
      (let ((layout (decknix-layout--capture accurate)))
        (cond
         ((null layout)
          (unless quiet (message "decknix: no GUI frames; saved layout left as it was")))
         ((decknix-layout--write layout)
          (unless quiet
            (message "decknix: layout saved (%s)" (decknix-layout--summary layout))))
         (t (unless quiet (message "decknix: layout unchanged")))))
    (error (message "decknix: layout save failed: %s" (error-message-string err))
           nil)))

;; -- Summary / recency ------------------------------------------------------

(defun decknix-layout--session-entries (layout)
  "Agent session entries recorded in LAYOUT.  Pure."
  (delq nil (mapcar (lambda (b)
                      (and (eq (plist-get (cdr b) :kind) 'agent)
                           (plist-get (cdr b) :session)))
                    (plist-get layout :buffers))))

(defun decknix-layout--summary (layout)
  "One-line description of LAYOUT, e.g. \"2 frames, 5 tabs, 3 sessions\".  Pure."
  (let* ((frames (plist-get layout :frames))
         (tabs (apply #'+ (mapcar (lambda (f) (length (plist-get f :tabs))) frames)))
         (sessions (length (decknix-layout--session-entries layout))))
    (format "%d frame%s, %d tab%s, %d session%s"
            (length frames) (if (= (length frames) 1) "" "s")
            tabs (if (= tabs 1) "" "s")
            sessions (if (= sessions 1) "" "s"))))

(defun decknix-layout--recent-p (layout now)
  "Non-nil when LAYOUT is younger than `decknix-layout-restore-max-age' at NOW.
Pure."
  (let ((at (plist-get layout :saved-at)))
    (and (numberp at) (< (- now at) decknix-layout-restore-max-age))))

(defun decknix-layout--age-string (layout now)
  (let ((s (max 0 (- now (or (plist-get layout :saved-at) now)))))
    (cond ((< s 120) "just now")
          ((< s 7200) (format "%dm ago" (/ s 60)))
          ((< s 172800) (format "%dh ago" (/ s 3600)))
          (t (format "%dd ago" (/ s 86400))))))

;; -- Frame geometry ---------------------------------------------------------

(defun decknix-layout--position-value (v)
  "Pixel value of a frame position V: N, (+ N) or (- N).  Pure."
  (cond ((numberp v) v)
        ((and (consp v) (memq (car v) '(+ -)) (numberp (cadr v)))
         (if (eq (car v) '-) (- (cadr v)) (cadr v)))))

(defun decknix-layout--params-on-screen (params workareas)
  "Return PARAMS, dropping left/top when they fall outside every WORKAREA.  Pure.
WORKAREAS are (X Y W H) lists, as in `display-monitor-attributes-list'.
A frame saved on a monitor that is no longer attached would otherwise
open off-screen; without a position the window system places it."
  (let ((x (decknix-layout--position-value (alist-get 'left params)))
        (y (decknix-layout--position-value (alist-get 'top params))))
    (if (and x y
             (seq-some (lambda (wa)
                         (pcase-let ((`(,wx ,wy ,ww ,wh) wa))
                           (and (<= wx x) (< x (+ wx ww)) (<= wy y) (< y (+ wy wh)))))
                       workareas))
        params
      (seq-remove (lambda (p) (memq (car p) '(left top))) params))))

(defun decknix-layout--workareas ()
  (delq nil (mapcar (lambda (m) (alist-get 'workarea m))
                    (ignore-errors (display-monitor-attributes-list)))))

;; -- Restore: buffers -------------------------------------------------------

(defvar-local decknix-layout--placeholder-entry nil
  "Previous-sessions entry this placeholder resumes.")
(defvar-local decknix-layout--placeholder-target nil
  "The live session buffer once this placeholder has been resumed.")

(defvar decknix-layout-placeholder-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'decknix-layout-placeholder-resume)
    map))

(define-derived-mode decknix-layout-placeholder-mode special-mode "Layout-Session"
  "Stands in for an agent session recorded in a saved layout.
\\<decknix-layout-placeholder-mode-map>\\[decknix-layout-placeholder-resume] resumes it in every window showing this buffer.")

(defun decknix-layout--placeholder-follow (window)
  "Swap WINDOW to the resumed session if this placeholder has one.
Runs from `window-buffer-change-functions', so a placeholder in a tab
that was in the background at resume time is replaced the moment that
tab is shown, without walking other tabs' saved configurations."
  (let ((buf (window-buffer window)))
    (when (buffer-live-p buf)
      (let ((target (buffer-local-value 'decknix-layout--placeholder-target buf)))
        (when (buffer-live-p target)
          (set-window-buffer window target))))))

(defun decknix-layout--placeholder (entry)
  "Return a placeholder buffer for session ENTRY."
  (let* ((label (or (alist-get 'name entry) (alist-get 'session-id entry) "session"))
         (buf (get-buffer-create (format "*Resume: %s*" (string-trim label "\\*+" "\\*+")))))
    (with-current-buffer buf
      (unless (derived-mode-p 'decknix-layout-placeholder-mode)
        (decknix-layout-placeholder-mode))
      (setq decknix-layout--placeholder-entry entry)
      (add-hook 'window-buffer-change-functions #'decknix-layout--placeholder-follow nil t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Agent session %s\n" label)
                (format "Session %s\n\n" (or (alist-get 'session-id entry) "?"))
                (substitute-command-keys
                 "\\<decknix-layout-placeholder-mode-map>\\[decknix-layout-placeholder-resume] resumes it here.\n"))))
    buf))

(defun decknix-layout--live-session-buffer (entry)
  (or (and (fboundp 'decknix--agent-find-live-buffer-for-conv-key)
           (decknix--agent-find-live-buffer-for-conv-key (alist-get 'conv-key entry)))
      (and (fboundp 'decknix--agent-find-live-buffer-for-session-id)
           (decknix--agent-find-live-buffer-for-session-id (alist-get 'session-id entry)))))

(defun decknix-layout--resume-entry (entry)
  "Resume session ENTRY without disturbing windows; return its buffer or nil.
Goes through `decknix--sidebar-restore-previous-session', the sidebar's
`p' path, so the freshest snapshot is resumed and the session leaves the
Previous list."
  (or (decknix-layout--live-session-buffer entry)
      (let ((before (and (fboundp 'agent-shell-buffers) (agent-shell-buffers))))
        (save-window-excursion
          (cond
           ((fboundp 'decknix--sidebar-restore-previous-session)
            (decknix--sidebar-restore-previous-session entry nil))
           ((and (fboundp 'decknix--agent-session-resume) (alist-get 'session-id entry))
            (decknix--agent-session-resume
             (alist-get 'session-id entry) 20 nil
             (alist-get 'workspace entry) (alist-get 'conv-key entry)))))
        (or (decknix-layout--live-session-buffer entry)
            (car (seq-difference (and (fboundp 'agent-shell-buffers) (agent-shell-buffers))
                                 before))))))

(defun decknix-layout--resume-placeholder (placeholder)
  "Resume PLACEHOLDER's session and show it wherever PLACEHOLDER is shown.
Returns the session buffer, or nil if it could not be resumed."
  (let* ((entry (buffer-local-value 'decknix-layout--placeholder-entry placeholder))
         (target (and entry (decknix-layout--resume-entry entry))))
    (when (buffer-live-p target)
      (with-current-buffer placeholder
        (setq decknix-layout--placeholder-target target)
        (rename-buffer (concat " " (buffer-name)) t))
      (dolist (w (get-buffer-window-list placeholder nil t))
        (set-window-buffer w target)))
    target))

(defun decknix-layout-placeholder-resume ()
  "Resume the agent session this placeholder stands for."
  (interactive)
  (unless (decknix-layout--resume-placeholder (current-buffer))
    (user-error "Could not resume this session; try the sidebar's Previous list")))

(defun decknix-layout--resolve-buffer (name ref)
  "Return a live buffer for saved buffer NAME described by REF, or nil.
Never signals: a file that has gone, a directory that moved or a
session that will not resume just yields nil and the window falls back."
  (ignore-errors
    (pcase (plist-get ref :kind)
      ('file (let ((f (plist-get ref :file)))
               (or (find-buffer-visiting f)
                   (and (file-exists-p f) (find-file-noselect f t)))))
      ('dired (let ((d (plist-get ref :dir)))
                (and (file-directory-p d) (dired-noselect d))))
      ('magit (let ((d (plist-get ref :dir)))
                (and (file-directory-p d) (fboundp 'magit-status-setup-buffer)
                     (save-window-excursion
                       (let ((b (magit-status-setup-buffer d)))
                         (and (bufferp b) b))))))
      ('agent (let ((entry (plist-get ref :session)))
                (or (decknix-layout--live-session-buffer entry)
                    (decknix-layout--placeholder entry))))
      ('sidebar (get-buffer-create agent-shell-workspace-sidebar-buffer-name))
      ('command (or (get-buffer name)
                    (decknix-layout--recreate name (plist-get ref :fn))))
      ;; Layouts saved before `command' existed recorded the boards as
      ;; `other'; matching by name brings those back too.
      (_ (or (get-buffer name)
             (let ((fn (decknix-layout--recreate-fn name)))
               (and fn (decknix-layout--recreate name fn))))))))

(defun decknix-layout--fallback-buffer ()
  (if (fboundp 'get-scratch-buffer-create)
      (get-scratch-buffer-create)
    (get-buffer-create "*scratch*")))

;; -- Restore: frames and tabs ------------------------------------------------

(defun decknix-layout--put-tab (state mapping fallback)
  "Show window STATE in the selected tab, buffers renamed through MAPPING."
  (let ((renamed (decknix-layout--state-rename-buffers state mapping fallback)))
    (condition-case nil
        (window-state-put renamed (frame-root-window) 'safe)
      (error (window-state-put (decknix-layout--state-without-pixels renamed)
                               (frame-root-window) 'safe))))
  ;; `window-state-put' keeps `window-side' but not the sidebar's
  ;; `no-delete-other-windows', so C-x 1 would delete it; see
  ;; `decknix-layout-group--protect-side-windows'.
  (walk-windows (lambda (w)
                  (when (window-parameter w 'window-side)
                    (set-window-parameter w 'no-delete-other-windows t)))
                nil (selected-frame)))

(defun decknix-layout--restore-tabs (tabs current mapping fallback)
  "Rebuild TABS in the selected frame, then select the one at index CURRENT.
Every tab is made and filled before any is selected, with
`tab-bar-tab-post-select-functions' bound to nil, so a hook reacting to
a half-built tab (the Agents tab's buffer isolation, which switches tabs
when a non-agent buffer is shown) cannot move later tabs' windows.

Not conditional on `tab-bar-mode': a fresh daemon has not turned it on
yet when the startup restore runs, and gating on it restored only the
selected tab of every frame.  Tabs exist as a frame parameter either
way, and `tab-bar-new-tab' turns the bar on as `tab-bar-show' says."
  (let ((tab-bar-tab-post-select-functions nil))
    (tab-bar-close-other-tabs)
    (cl-loop for tab in tabs
             for i from 0
             do (when (> i 0) (tab-bar-new-tab))
             (ignore-errors (decknix-layout--put-tab (plist-get tab :state) mapping fallback))
             ;; The empty name hands the kept first tab back to the
             ;; automatic name if this frame's old tab was named.
             (tab-bar-rename-tab (if (plist-get tab :explicit)
                                     (or (plist-get tab :name) "")
                                   "")))
    (tab-bar-select-tab (1+ current))))

(defun decknix-layout--restore-frame (frame model mapping fallback)
  "Rebuild MODEL's tabs in FRAME, replacing the tabs it has."
  (with-selected-frame frame
    (let ((params (decknix-layout--params-on-screen
                   (plist-get model :params) (decknix-layout--workareas))))
      (ignore-errors (modify-frame-parameters frame params)))
    (let* ((tabs (plist-get model :tabs))
           (current (max 0 (min (or (plist-get model :current-tab) 0)
                                (1- (length tabs))))))
      (if (fboundp 'tab-bar-new-tab)
          (decknix-layout--restore-tabs tabs current mapping fallback)
        (ignore-errors
          (decknix-layout--put-tab (plist-get (nth current tabs) :state)
                                   mapping fallback))))
    (when (and (get-buffer-window agent-shell-workspace-sidebar-buffer-name frame)
               (fboundp 'agent-shell-workspace-sidebar-open))
      (ignore-errors (agent-shell-workspace-sidebar-open)))))

;;;###autoload
(defun decknix-layout-restore (&optional previous sessions)
  "Restore the saved frames, tabs and windows.
With PREVIOUS (\\[universal-argument]) restore the layout of the run
before the last one instead (kept as `<file>.prev').  SESSIONS non-nil
resumes the recorded agent sessions; interactively that follows
`decknix-layout-restore-sessions'.  Reuses the open GUI frames, the
selected one first, and makes more as needed."
  (interactive (list current-prefix-arg decknix-layout-restore-sessions))
  (let* ((file (if previous (concat decknix-layout-persist-file ".prev")
                 decknix-layout-persist-file))
         (layout (or (decknix-layout--read-file file)
                     (user-error "No saved layout in %s" file)))
         (frames (or (decknix-layout--gui-frames)
                     (user-error "Restore needs a GUI frame")))
         (missing 0)
         (resumed 0)
         (selected nil))
    ;; The restored windows are the arrangement the user had.  The sidebar
    ;; tile preference would otherwise re-tile the selected frame on its
    ;; next refresh with the N most recent sessions, which after a restart
    ;; are whatever the broker reattach touched last.  Cycling the tile
    ;; count (`t' in the sidebar) lifts this.
    (setq decknix--sidebar-tile-auto-suspended t)
    ;; Isolation off while building: with it on, any buffer shown while
    ;; the selected tab is Agents (a board command popping to its buffer,
    ;; a session being resumed) switches tabs under us.
    (let ((agent-shell-workspace--isolation-active nil))
      (let ((fallback (decknix-layout--fallback-buffer))
            (mapping
             (delq nil
                   (mapcar (lambda (b)
                             (let ((buf (decknix-layout--resolve-buffer (car b) (cdr b))))
                               (if (buffer-live-p buf)
                                   (cons (car b) (buffer-name buf))
                                 (setq missing (1+ missing))
                                 nil)))
                           (plist-get layout :buffers)))))
        (dolist (model (plist-get layout :frames))
          (let ((frame (or (pop frames)
                           (make-frame (decknix-layout--params-on-screen
                                        (plist-get model :params)
                                        (decknix-layout--workareas))))))
            (decknix-layout--restore-frame frame model mapping (buffer-name fallback))
            (when (plist-get model :selected) (setq selected frame)))))
      (when sessions
        (dolist (buf (buffer-list))
          (when (and (buffer-live-p buf)
                     (buffer-local-value 'decknix-layout--placeholder-entry buf)
                     (not (buffer-local-value 'decknix-layout--placeholder-target buf))
                     (condition-case err
                         (decknix-layout--resume-placeholder buf)
                       (error (message "decknix: resume failed: %s"
                                       (error-message-string err))
                              nil)))
            (setq resumed (1+ resumed)))))
      ;; A sidebar shown only in a background tab was created as a plain
      ;; buffer; give it its mode and content now, not when that tab is
      ;; next selected.
      (let ((sb (get-buffer agent-shell-workspace-sidebar-buffer-name)))
        (when (and sb (fboundp 'agent-shell-workspace-sidebar-open)
                   (not (with-current-buffer sb
                          (derived-mode-p 'agent-shell-workspace-sidebar-mode))))
          (save-window-excursion (ignore-errors (agent-shell-workspace-sidebar-open)))))
      (when (frame-live-p selected) (select-frame-set-input-focus selected)))
    ;; After the `let', so the isolation decision made for the tab that
    ;; ended up selected is the one that stays.
    (when (and (fboundp 'agent-shell-workspace--on-tab-selected)
               (get-buffer agent-shell-workspace-sidebar-buffer-name))
      (add-hook 'tab-bar-tab-post-select-functions #'agent-shell-workspace--on-tab-selected)
      (ignore-errors (agent-shell-workspace--on-tab-selected)))
    (message "decknix: restored %s%s%s"
             (decknix-layout--summary layout)
             (if sessions (format "; resumed %d" resumed) "; sessions resume on RET")
             (if (> missing 0)
                 (format "; %d buffer%s gone, shown as *scratch*"
                         missing (if (= missing 1) "" "s"))
               ""))))

;; -- Startup offer ------------------------------------------------------------

(defvar decknix-layout--offered nil
  "Non-nil once this daemon has offered the saved layout.")

(defun decknix-layout--offer (frame)
  "Offer the saved layout in FRAME, per `decknix-layout-restore-on-start'."
  (when (frame-live-p frame)
    (with-selected-frame frame
      (let ((layout (decknix-layout--read-file))
            (now (float-time)))
        (when (and layout (decknix-layout--recent-p layout now))
          (let ((desc (format "%s, saved %s" (decknix-layout--summary layout)
                              (decknix-layout--age-string layout now)))
                (key (substitute-command-keys "\\[decknix-layout-restore]")))
            (pcase decknix-layout-restore-on-start
              ('notify (message "decknix: saved layout (%s); %s restores it" desc key))
              ('t (decknix-layout-restore nil decknix-layout-restore-sessions))
              ('ask
               (pcase (condition-case nil
                          (read-char-choice
                           (format "Restore saved layout (%s)? [y]es with sessions, [l]ayout only, [n]o: "
                                   desc)
                           '(?y ?l ?n ?q))
                        (quit nil))
                 (?y (decknix-layout-restore nil t))
                 (?l (decknix-layout-restore nil nil))
                 (_ (message "decknix: not restored; %s restores it later" key)))))))))))

(defun decknix-layout--offer-safely (frame)
  "`decknix-layout--offer' from a timer: report errors instead of raising them."
  (condition-case err
      (decknix-layout--offer frame)
    (error (message "decknix: layout restore failed: %s" (error-message-string err)))))

(defun decknix-layout--maybe-offer ()
  "Offer the saved layout once, on the first GUI client frame of the daemon.
Deferred to an idle timer: `server-after-make-frame-hook' runs inside the
server's process filter, where a prompt would hold up the client that
asked for the frame."
  (let ((frame (selected-frame)))
    (when (and (not decknix-layout--offered)
               (not noninteractive)
               decknix-layout-restore-on-start
               (display-graphic-p frame))
      (setq decknix-layout--offered t)
      (run-with-idle-timer 0.5 nil #'decknix-layout--offer-safely frame))))

;; -- Hooks --------------------------------------------------------------------

(defun decknix-layout--save-on-kill ()
  "Save the layout as Emacs exits.  Never signals."
  (decknix-layout-save t t))

(defun decknix-layout--save-before-last-frame (frame)
  "Save while FRAME, the last GUI frame, still exists.
Closing the last frame and then restarting the daemon would otherwise
reach `kill-emacs-hook' with nothing to record."
  (when (and (frame-live-p frame) (display-graphic-p frame)
             (equal (decknix-layout--gui-frames) (list frame)))
    (decknix-layout-save t t)))

(defun decknix-layout--autosave ()
  (when (decknix-layout--gui-frames)
    (decknix-layout-save t nil)))

(defvar decknix-layout--autosave-timer nil)

;;;###autoload
(defun decknix-layout-persist-enable ()
  "Install the save hooks, the autosave timer and the startup offer.
Idempotent; a no-op in batch."
  (unless noninteractive
    (add-hook 'kill-emacs-hook #'decknix-layout--save-on-kill)
    (add-hook 'delete-frame-functions #'decknix-layout--save-before-last-frame)
    (add-hook 'server-after-make-frame-hook #'decknix-layout--maybe-offer)
    (when (timerp decknix-layout--autosave-timer)
      (cancel-timer decknix-layout--autosave-timer))
    (setq decknix-layout--autosave-timer
          (and decknix-layout-autosave-interval
               (run-with-timer decknix-layout-autosave-interval
                               decknix-layout-autosave-interval
                               #'decknix-layout--autosave)))))

(provide 'decknix-layout-persist)
;;; decknix-layout-persist.el ends here
