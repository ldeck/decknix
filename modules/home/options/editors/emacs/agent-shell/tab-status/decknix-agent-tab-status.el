;;; decknix-agent-tab-status.el --- Tint tab-bar tabs by agent status -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: decknix, agent, agent-shell, tab-bar

;;; Commentary:
;;
;; Background-tints a tab-bar tab by the status of the agent it holds, so a
;; row of tabs shows at a glance which agents are working, waiting on you,
;; finished, etc.  Only tabs that contain a SINGLE window showing an
;; agent-shell buffer are tinted — a dedicated per-agent tab — so multi-window
;; tabs and the Agents workspace tab (agent + sidebar) are left neutral.
;;
;; Wiring: `decknix-agent-tab-status-install' sets Emacs'
;; `tab-bar-tab-face-function' to `decknix-agent-tab-bar-face'.  The tab-bar
;; keymap is rebuilt (uncached) on every redisplay, so the existing agent
;; status poll's `force-mode-line-update' repaints the tabs — no extra timer.
;; A per-buffer throttle keeps the status lookup cheap even under frequent
;; redisplay.
;;
;; Design: the parsing/colour/face-composition layer is PURE (no buffers, no
;; frames) and ERT-tested; only the per-tab buffer resolution + status probe
;; touch live state, and the whole face function is wrapped so a bad tab can
;; never break tab-bar rendering.

;;; Code:

(require 'subr-x)

;; Resolved at runtime in the daemon's load-path (carved siblings / externals).
(declare-function decknix--header-detect-status "decknix-agent-header" ())
(defvar shell-maker--busy)

(defgroup decknix-agent-tab-status nil
  "Tint tab-bar tabs by the status of the agent they hold."
  :group 'decknix)

(defcustom decknix-agent-tab-status-enable t
  "When non-nil, tint single-agent tabs by agent status.
Applied by `decknix-agent-tab-status-install'."
  :type 'boolean :group 'decknix-agent-tab-status)

(defcustom decknix-agent-tab-status-colors
  '(("working"      . "#3a330a")   ; amber — in progress
    ("netfail"      . "#4a0f14")   ; deep red — turn died on the link (#162)
    ("waiting"      . "#3a1418")   ; red   — needs YOU (permission/input)
    ("asking"       . "#3a2410")   ; orange — needs YOU (ended on a question)
    ("ready"        . "#123010")   ; green — idle, ready for a prompt
    ("finished"     . "#0f2e30")   ; cyan  — just completed
    ("initializing" . "#262626")   ; grey  — starting up
    ("killed"       . "#2a1414"))  ; maroon — process gone
  "Alist of agent status string -> tab background colour.
Tuned for dark themes; a status not listed (or mapped to nil) gets no tint.
Override to match your theme, or set to nil to disable tinting entirely."
  :type '(alist :key-type string :value-type (choice color (const nil)))
  :group 'decknix-agent-tab-status)

(defcustom decknix-agent-tab-status-throttle 0.5
  "Minimum seconds between agent-status probes for a given buffer.
The tab-bar face function runs on every redisplay; this per-buffer throttle
keeps the status lookup off the hot path."
  :type 'number :group 'decknix-agent-tab-status)

;; Per-buffer throttled status cache (buffer-local in each agent buffer).
(defvar-local decknix--tab-status-cached nil)
(defvar-local decknix--tab-status-cached-time 0.0)

;; ---------------------------------------------------------------------------
;; Pure layer — ERT-tested.
;; ---------------------------------------------------------------------------

(defun decknix--tab-ws-buffer-names (node)
  "Collect window buffer names from a window-state NODE (recursive).
Walks the cons tree and returns the name from every `(buffer NAME . _)'
window entry — one per live window — so the count equals the window count.
Ignores `prev-buffers'/`next-buffers' and size params (they carry no `buffer'
marker).  Pure: no buffer or frame access."
  (cond
   ((not (consp node)) nil)
   ((and (eq (car node) 'buffer)
         (or (stringp (cadr node)) (bufferp (cadr node))))
    (list (if (bufferp (cadr node)) (buffer-name (cadr node)) (cadr node))))
   (t (append (decknix--tab-ws-buffer-names (car node))
              (decknix--tab-ws-buffer-names (cdr node))))))

(defun decknix-agent-tab-status-background (status)
  "Return the tab background colour for agent STATUS, or nil.  Pure."
  (and status (cdr (assoc status decknix-agent-tab-status-colors))))

(defun decknix--tab-status-face (current-p bg)
  "Compose the tab face: the base tab face plus BG background when non-nil.
CURRENT-P selects the active vs inactive base face; BG nil leaves the tab
neutral (returns the base face unchanged).  Pure."
  (let ((base (if current-p 'tab-bar-tab 'tab-bar-tab-inactive)))
    (if bg (list :inherit base :background bg) base)))

;; ---------------------------------------------------------------------------
;; Live layer — per-tab buffer resolution + throttled status probe.
;; ---------------------------------------------------------------------------

(defun decknix--tab-agent-buffer (tab)
  "Return the agent-shell buffer of TAB when it is a single-window agent tab.
For the current tab this reads the frame's live windows; for a background tab
it reads the stored window-state.  Returns nil unless the tab has exactly one
window and that window shows an `agent-shell-mode' buffer."
  (let ((buf
         (if (eq (car tab) 'current-tab)
             (let ((wins (window-list (selected-frame) 'no-minibuf)))
               (when (= 1 (length wins)) (window-buffer (car wins))))
           (let ((names (decknix--tab-ws-buffer-names (alist-get 'ws tab))))
             (when (= 1 (length names)) (get-buffer (car names)))))))
    (when (and (buffer-live-p buf)
               (with-current-buffer buf (derived-mode-p 'agent-shell-mode)))
      buf)))

(defun decknix--tab-buffer-status (buf)
  "Return BUF's agent status, throttled per-buffer to keep the face cheap."
  (with-current-buffer buf
    (let ((now (float-time)))
      (when (> (- now decknix--tab-status-cached-time)
               decknix-agent-tab-status-throttle)
        (setq decknix--tab-status-cached
              (ignore-errors (decknix--header-detect-status))
              decknix--tab-status-cached-time now))
      decknix--tab-status-cached)))

(defun decknix-agent-tab-bar-face (tab)
  "`tab-bar-tab-face-function' that tints single-agent tabs by status.
Never signals — any error falls back to the default tab face so a bad tab or
window-state can't break tab-bar rendering."
  (or (ignore-errors
        (let* ((current-p (eq (car tab) 'current-tab))
               (buf (decknix--tab-agent-buffer tab))
               (status (and buf (decknix--tab-buffer-status buf)))
               (bg (decknix-agent-tab-status-background status)))
          (decknix--tab-status-face current-p bg)))
      (if (eq (car tab) 'current-tab) 'tab-bar-tab 'tab-bar-tab-inactive)))

;;;###autoload
(defun decknix-agent-tab-status-install ()
  "Install (or remove) the agent-status tab tint per `decknix-agent-tab-status-enable'."
  (if decknix-agent-tab-status-enable
      (setq tab-bar-tab-face-function #'decknix-agent-tab-bar-face)
    (when (eq tab-bar-tab-face-function #'decknix-agent-tab-bar-face)
      (setq tab-bar-tab-face-function #'tab-bar-tab-face-default)))
  (when (bound-and-true-p tab-bar-mode)
    (force-mode-line-update t)))

(provide 'decknix-agent-tab-status)
;;; decknix-agent-tab-status.el ends here
